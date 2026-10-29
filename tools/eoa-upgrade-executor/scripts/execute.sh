#!/usr/bin/env bash
# Sends the transactions of a plan in order, waiting for each receipt before the next.
#
#   execute.sh --plan DIR/plan.json --mode impersonate|key --out DIR [--rpc-url URL] [--dry-run]
#
#   impersonate  for an anvil fork (--rpc-url): each sender is impersonated
#   key          signs with the keystore in $EXECUTOR_KEYSTORE (the JSON itself)
#                and $EXECUTOR_KEYSTORE_PASSWORD, against the network's two
#                independent RPCs from config.json (rpcUrl, secondaryRpcUrl)
#
# The key never reaches a command line: cast has no environment variable for a
# raw private key, so the keystore and its password are written to two 0600
# files in a private temp directory, handed to cast as ETH_KEYSTORE and
# ETH_PASSWORD (both paths) on the two commands that need them, and deleted on
# exit. Neither value is printed.
#
# An RPC can lie, so in key mode both RPCs must agree before anything moves on:
# on the chain id, on the sender's nonce (latest and pending), on eth_call
# succeeding right before each send, and on each receipt (same block hash,
# status 1). Gas and fees take the higher answer of the two and are capped by
# config.json (priority fee, max fee per gas, gas per tx, and a fee total per
# run that reserves each tx's worst case before signing and never trusts a
# receipt's fee fields).
# The signed tx goes to both RPCs. Disagreement, a missing answer after brief
# retries, or a cap exceeded stops the run; a cap is checked before signing.
#
# Fees are EIP-1559 (maxFee = baseFeeMultiplier * base fee + priority fee,
# clamped to the cap). Never legacy: a legacy tx priced at eth_gasPrice can sit
# below the base fee forever.
#
# --dry-run (key mode): runs the key check and the pre-send checks for the
# first transaction, then stops. Nothing is signed or sent.
#
# Writes to DIR: results.jsonl, results.md, tx-<i>.receipt.json and, in
# impersonate mode, tx-<i>.trace.json (callTracer); tx-<i>.failure.txt when a
# pre-send eth_call reverts.

set +x
# Take the secrets out of the environment before anything else runs, so that
# no child process inherits them.
keystore_json="${EXECUTOR_KEYSTORE:-}"
keystore_password="${EXECUTOR_KEYSTORE_PASSWORD:-}"
unset EXECUTOR_KEYSTORE EXECUTOR_KEYSTORE_PASSWORD

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

plan="" mode="" out="" rpc="" dry_run=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --rpc-url) rpc="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ ! -f "$plan" ] || [ -z "$out" ]; then
  die "usage: execute.sh --plan plan.json --mode impersonate|key --out DIR [--rpc-url URL] [--dry-run]"
fi
case "$mode" in impersonate | key) ;; *) die "--mode must be impersonate or key" ;; esac
if [ "$mode" = impersonate ] && [ "$dry_run" = true ]; then die "--dry-run applies to key mode only"; fi
if [ "$mode" = impersonate ] && [ -z "$rpc" ]; then die "impersonate mode needs --rpc-url (the anvil fork)"; fi
if [ "$mode" = key ] && [ -n "$rpc" ]; then die "key mode uses the RPCs from config.json; --rpc-url is for impersonate mode"; fi

if [ "$mode" != key ]; then keystore_json="" keystore_password=""; fi

check_foundry
mkdir -p "$out"

network="$(jq -r .network "$plan")"
chain_id="$(jq -r .chainId "$plan")"
[ "$chain_id" = "$(chain_id_of_network "$network")" ] || die "plan chain id $chain_id does not match config for $network"
net_cfg() { jq -r --arg n "$network" ".networks[\$n].$1 // \"\"" "$CONFIG_FILE"; }
explorer="$(net_cfg explorerTxUrl)"
buffer_pct="$(cfg .execution.gasLimitBufferPercent)"
max_gas="$(cfg .execution.maxTxGasLimit)"
fee_mult="$(cfg .execution.baseFeeMultiplier)"
receipt_timeout="$(cfg .execution.receiptTimeoutSeconds)"
poll="$(cfg .execution.receiptPollSeconds)"
retries="$(cfg .execution.rpcAgreementRetries)"
priority_cap="$(net_cfg maxPriorityFeePerGasWei)"
fee_cap="$(net_cfg maxFeePerGasWei)"
run_budget="$(net_cfg maxRunFeeWei)"
sender="$(jq -r '.sender // ""' "$plan")"
count="$(jq '.transactions | length' "$plan")"

# All wei amounts stay far below 2^63 so that bash arithmetic cannot wrap.
is_uint18() { [[ "$1" =~ ^[0-9]{1,18}$ ]]; }
for v in max_gas priority_cap fee_cap run_budget; do
  is_uint18 "${!v}" || die "config for $network: $v must be a decimal integer below 10^18, got '${!v}'"
done
[ "$fee_cap" -le $((4611686018427387904 / max_gas)) ] || die "config: maxFeePerGasWei * maxTxGasLimit must stay below 2^62"
[ "$run_budget" -le 4611686018427387904 ] || die "config: maxRunFeeWei must stay below 2^62"

if [ "$mode" = key ]; then
  rpc="$(net_cfg rpcUrl)"
  rpc2="$(net_cfg secondaryRpcUrl)"
  if [ -z "$rpc" ] || [ -z "$rpc2" ] || [ "$rpc" = "$rpc2" ]; then
    die "key mode needs two different RPCs for $network in config.json (rpcUrl, secondaryRpcUrl)"
  fi
  rpcs=("$rpc" "$rpc2")
else
  rpcs=("$rpc")
  retries=0 # one local fork: nothing to wait for
fi
rpc_name() { if [ "$1" = "${rpcs[0]}" ]; then echo "primary RPC"; else echo "secondary RPC"; fi; }

results="$out/results.jsonl"
: >"$results"
outcome="stopped before completion"
key_dir=""

write_summary() {
  local title ex=""
  if [ "$mode" = key ]; then ex="$explorer"; fi
  case "$mode:$dry_run" in
    impersonate:*) title="Fork simulation" ;;
    key:true) title="Broadcast (dry run)" ;;
    *) title="Broadcast" ;;
  esac
  {
    printf '## %s: %s\n\n' "$title" "$(md_escape "$outcome")"
    if [ -s "$results" ]; then
      printf '| # | tx hash | status | block | gas used / limit | nonce |\n|---|---|---|---|---|---|\n'
      jq -r --arg ex "$ex" '
        "| \(.index) | " + (if $ex != "" then "[`\(.hash)`](\($ex)\(.hash))" else "`\(.hash)`" end)
        + " | \(.status) | \(.blockNumber) | \(.gasUsed) / \(.gasLimit) | \(.nonce) |"' "$results"
    fi
  } >"$out/results.md"
}
on_exit() {
  local rc=$?
  if [ -n "$key_dir" ]; then
    rm -f "$key_dir/keystore.json" "$key_dir/password"
    rmdir "$key_dir" 2>/dev/null || true
  fi
  write_summary
  exit "$rc"
}
trap on_exit EXIT

# Like die, and the reason also lands in results.md.
stop() {
  outcome="$*"
  die "$@"
}

# The helpers' locals must not shadow a global the EXIT trap reads (out,
# outcome, results, mode, ...): bash scoping is dynamic, and a stop inside a
# helper runs the trap in the helper's scope.

# consensus DESC CMD...: runs `CMD --rpc-url R` against every RPC and sets
# $answer when all of them answer the same. Retries briefly; disagreement or a
# missing answer then stops the run.
consensus() {
  local desc="$1" try=0 r resp first ok
  shift
  while :; do
    first="" ok=true
    for r in "${rpcs[@]}"; do
      if ! resp="$("$@" --rpc-url "$r" 2>/dev/null)"; then ok=false; break; fi
      if [ -z "$first" ]; then first="$resp"; elif [ "$resp" != "$first" ]; then ok=false; break; fi
    done
    if [ "$ok" = true ]; then
      answer="$first"
      return 0
    fi
    try=$((try + 1))
    [ "$try" -le "$retries" ] || stop "the RPCs do not agree on $desc (or one did not answer); nothing more was sent"
    sleep "$poll"
  done
}

# max_of DESC CMD...: the highest integer answer of `CMD --rpc-url R` over the
# RPCs (gas estimates, fees), in $answer. Every RPC must answer.
max_of() {
  local desc="$1" r resp best=0
  shift
  for r in "${rpcs[@]}"; do
    resp="$("$@" --rpc-url "$r" 2>/dev/null)" || stop "the $(rpc_name "$r") did not answer $desc; nothing more was sent"
    resp="$(tr -d '"' <<<"$resp")"
    case "$resp" in 0x*) resp="$("$CAST" to-dec "$resp")" ;; esac
    is_uint18 "$resp" || stop "the $(rpc_name "$r") answered $desc with '$resp'; nothing more was sent"
    if [ "$resp" -gt "$best" ]; then best="$resp"; fi
  done
  answer="$best"
}

# ---------------------------------------------------------------- key
if [ "$mode" = key ]; then
  if [ "$(jq -r .simulationOnly "$plan")" != false ] || [ -z "$sender" ]; then
    stop "plan is simulation-only (more than one sender); refusing to sign"
  fi
  if [ -z "$keystore_json" ]; then
    [ "$dry_run" = true ] || stop "EXECUTOR_KEYSTORE is not set in this environment; nothing was sent"
    log "no EXECUTOR_KEYSTORE in this environment; the dry run continues without the key check"
  else
    [ -n "$keystore_password" ] || stop "EXECUTOR_KEYSTORE_PASSWORD is not set; nothing was sent"
    key_dir="$(umask 077 && mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/eoa-key.XXXXXX")"
    # printf is a shell builtin: the values go straight to the files, never to argv.
    (umask 077 && printf '%s' "$keystore_json" >"$key_dir/keystore.json" && printf '%s' "$keystore_password" >"$key_dir/password")
    keystore_json="" keystore_password=""
    key_address="$(ETH_KEYSTORE="$key_dir/keystore.json" ETH_PASSWORD="$key_dir/password" "$CAST" wallet address 2>/dev/null)" ||
      stop "cannot decrypt EXECUTOR_KEYSTORE with EXECUTOR_KEYSTORE_PASSWORD; nothing was sent"
    [ "$(lower "$key_address")" = "$(lower "$sender")" ] ||
      stop "EXECUTOR_KEYSTORE is for $key_address but the plan's sender is $sender; nothing was sent"
    log "EXECUTOR_KEYSTORE matches the plan sender $sender"
  fi
fi

consensus "the chain id" "$CAST" chain-id
[ "$answer" = "$chain_id" ] || stop "chain id mismatch: the RPCs serve $answer, expected $chain_id"

# ---------------------------------------------------------------- helpers
# Sets $nonce for sender $1. In key mode the loop tracks the expected nonce ($2)
# itself: wait until the RPCs have caught up with our last receipt, and stop if
# the account moved on without us or has anything pending.
next_nonce() {
  local from="$1" expected="$2" latest waited=0
  while :; do
    consensus "the nonce of $from" "$CAST" nonce "$from" --block latest
    latest="$answer"
    if [ -z "$expected" ] || [ "$latest" -ge "$expected" ]; then break; fi
    [ "$waited" -lt "$receipt_timeout" ] || stop "the RPCs still report nonce $latest for $from, expected $expected"
    sleep "$poll"
    waited=$((waited + poll))
  done
  if [ -n "$expected" ] && [ "$latest" -ne "$expected" ]; then
    stop "nonce of $from is $latest, expected $expected: something else sent from this account during the run"
  fi
  consensus "the pending nonce of $from" "$CAST" nonce "$from" --block pending
  [ "$answer" -eq "$latest" ] ||
    stop "$from has $((answer - latest)) pending transaction(s) in the mempool; clear them before running"
  nonce="$latest"
}

# Sets $receipt for tx hash $1 once every RPC returns it with the same block
# hash and status. Waits up to receiptTimeoutSeconds for the receipts to appear.
wait_receipt() {
  local hash="$1" waited=0 disagreements=0 r resp fields first missing mismatch
  while :; do
    first="" missing="" mismatch=false
    for r in "${rpcs[@]}"; do
      if ! resp="$("$CAST" receipt --async --json "$hash" --rpc-url "$r" 2>/dev/null)"; then
        missing="$(rpc_name "$r")"
        break
      fi
      fields="$(jq -r '[(.transactionHash | ascii_downcase), .blockHash, .status] | join(" ")' <<<"$resp")"
      if [ -z "$first" ]; then
        first="$fields"
        receipt="$resp"
      elif [ "$fields" != "$first" ]; then
        mismatch=true
      fi
    done
    if [ -z "$missing" ] && [ "$mismatch" = false ]; then
      [ "${first%% *}" = "$(lower "$hash")" ] || stop "the receipt returned for $hash is for another transaction"
      return 0
    fi
    if [ "$mismatch" = true ]; then
      disagreements=$((disagreements + 1))
      [ "$disagreements" -le "$retries" ] ||
        stop "the RPCs disagree on the receipt of $hash (block hash or status); stopping, check it on an explorer"
    fi
    [ "$waited" -lt "$receipt_timeout" ] ||
      stop "no receipt for $hash from the ${missing:-other} after ${receipt_timeout}s; stopping, check it on an explorer before re-running (it may still be pending)"
    sleep "$poll"
    waited=$((waited + poll))
  done
}

# ---------------------------------------------------------------- loop
expected_nonce=""
# Fees reserved so far: each tx's worst case (gas limit x max fee, the values
# about to be signed), never credited back from a receipt, so that the run
# budget does not depend on what an RPC reports.
reserved=0
n=0
# fd 3, so that nothing in the loop body can swallow the list from stdin.
while IFS= read -r tx <&3; do
  i="$(jq -r .index <<<"$tx")"
  from="$(jq -r .from <<<"$tx")"
  to="$(jq -r .to <<<"$tx")"
  data="$(jq -r .data <<<"$tx")"
  wei="$(jq -r .valueWei <<<"$tx")"
  n=$((n + 1))
  log "---- tx $i ($n/$count): $from -> $to, $(jq -r .dataBytes <<<"$tx") calldata bytes, value $wei wei"

  if [ "$mode" = impersonate ]; then
    "$CAST" rpc anvil_impersonateAccount "$from" --rpc-url "$rpc" >/dev/null
    next_nonce "$from" ""
  else
    next_nonce "$from" "$expected_nonce"
  fi

  # Simulate on the current state of every RPC, right before sending.
  for r in "${rpcs[@]}"; do
    try=0
    until err="$("$CAST" call --from "$from" --value "$wei" "$to" "$data" --rpc-url "$r" 2>&1 >/dev/null)"; do
      try=$((try + 1))
      if [ "$try" -gt "$retries" ]; then
        printf '%s\n' "$err" >"$out/tx-$i.failure.txt"
        if [ "$mode" = impersonate ]; then
          "$CAST" call --trace --from "$from" --value "$wei" "$to" "$data" --rpc-url "$r" >>"$out/tx-$i.failure.txt" 2>&1 || true
        fi
        printf '%s\n' "$err" | tail -n 3 >&2
        stop "tx $i: eth_call reverts on the current state of the $(rpc_name "$r"); nothing more was sent (details: tx-$i.failure.txt)"
      fi
      sleep "$poll"
    done
  done

  max_of "eth_estimateGas" "$CAST" estimate --from "$from" --value "$wei" "$to" "$data"
  estimate="$answer"
  [ "$estimate" -le "$max_gas" ] || stop "tx $i: estimated gas $estimate exceeds the per-tx cap $max_gas; nothing more was sent"
  gas_limit=$((estimate * (100 + buffer_pct) / 100))
  [ "$gas_limit" -le "$max_gas" ] || gas_limit="$max_gas"
  max_of "the base fee" "$CAST" base-fee latest
  base_fee="$answer"
  max_of "eth_maxPriorityFeePerGas" "$CAST" rpc eth_maxPriorityFeePerGas
  priority_fee="$answer"

  # Fee caps, before anything is signed.
  [ "$priority_fee" -le "$priority_cap" ] ||
    stop "tx $i: priority fee $priority_fee exceeds the cap $priority_cap for $network (config.json); nothing more was sent"
  if [ "$base_fee" -gt "$fee_cap" ] || [ $((base_fee + priority_fee)) -gt "$fee_cap" ]; then
    stop "tx $i: base fee $base_fee + priority fee $priority_fee exceeds the max fee cap $fee_cap for $network (config.json); nothing more was sent"
  fi
  max_fee=$((base_fee * fee_mult + priority_fee))
  [ "$max_fee" -le "$fee_cap" ] || max_fee="$fee_cap"
  worst=$((gas_limit * max_fee))
  [ $((reserved + worst)) -le "$run_budget" ] ||
    stop "tx $i: worst-case fee $worst on top of the $reserved wei already reserved exceeds this run's fee budget $run_budget for $network (config.json); nothing more was sent"
  log "tx $i: eth_call ok; nonce $nonce, gas $estimate -> limit $gas_limit, maxFee $max_fee, priority $priority_fee (base $base_fee), worst-case fee $worst"

  if [ "$dry_run" = true ]; then
    log "sender balance: $("$CAST" balance --ether "$from" --rpc-url "$rpc") ETH"
    outcome="DRY RUN, all checks passed for tx $i; nothing was signed or sent"
    log "DRY RUN: stopping before tx $i; nothing was signed or sent"
    exit 0
  fi

  reserved=$((reserved + worst))
  fee_args=(--nonce "$nonce" --gas-limit "$gas_limit" --gas-price "$max_fee" --priority-gas-price "$priority_fee" --value "$wei")
  if [ "$mode" = impersonate ]; then
    hash="$("$CAST" send --unlocked --from "$from" --async "${fee_args[@]}" "$to" "$data" --rpc-url "$rpc")" ||
      stop "tx $i: send to the fork failed"
  else
    raw="$(ETH_KEYSTORE="$key_dir/keystore.json" ETH_PASSWORD="$key_dir/password" \
      "$CAST" mktx --chain "$chain_id" "${fee_args[@]}" "$to" "$data" 2>/dev/null)" ||
      stop "tx $i: signing failed; nothing more was sent"
    hash="$("$CAST" keccak "$raw")"
    log "tx $i: signed $hash; publishing to both RPCs"
    published="$("$CAST" publish --async "$raw" --rpc-url "$rpc")" ||
      stop "tx $i: publishing $hash failed; check it on an explorer before re-running"
    [ "$(lower "$published")" = "$(lower "$hash")" ] || stop "tx $i: RPC returned hash $published, signed $hash"
    "$CAST" publish --async "$raw" --rpc-url "$rpc2" >/dev/null 2>&1 ||
      log "tx $i: the secondary RPC did not accept it (it may already have it from the network)"
  fi
  log "tx $i: sent $hash; waiting for the receipt"
  wait_receipt "$hash"
  printf '%s\n' "$receipt" >"$out/tx-$i.receipt.json"
  status="$(jq -r .status <<<"$receipt")"
  block="$("$CAST" to-dec "$(jq -r .blockNumber <<<"$receipt")")"
  gas_used="$("$CAST" to-dec "$(jq -r .gasUsed <<<"$receipt")")"
  jq -nc --argjson i "$i" --arg h "$hash" --arg st "$status" --argjson b "$block" --argjson gu "$gas_used" \
    --argjson gl "$gas_limit" --argjson nonce "$nonce" \
    '{index: $i, hash: $h, status: (if $st == "0x1" then "success" else "REVERTED" end),
      blockNumber: $b, gasUsed: $gu, gasLimit: $gl, nonce: $nonce}' >>"$results"
  if [ "$mode" = impersonate ]; then
    "$CAST" rpc debug_traceTransaction "$hash" '{"tracer":"callTracer"}' --rpc-url "$rpc" >"$out/tx-$i.trace.json" 2>&1 || true
  fi
  if [ "$status" != "0x1" ]; then
    stop "tx $i REVERTED on-chain ($hash); nothing more was sent"
  fi
  log "tx $i: success in block $block, gas used $gas_used"
  expected_nonce=$((nonce + 1))
done 3< <(jq -c '.transactions[]' "$plan")

outcome="all $count transactions succeeded"
log "$outcome"
