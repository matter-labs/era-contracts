#!/usr/bin/env bash
# Sends the transactions of a plan in order, waiting for each receipt before the next.
#
#   execute.sh --plan DIR/plan.json --mode impersonate|key --out DIR [--rpc-url URL] [--dry-run]
#
#   impersonate  for an anvil fork: each sender is impersonated (fork simulation)
#   key          signs with the keystore in $EXECUTOR_KEYSTORE (the JSON itself)
#                and $EXECUTOR_KEYSTORE_PASSWORD, and publishes to --rpc-url
#                (default: the network's RPC from config.json)
#
# The key never reaches a command line: cast has no environment variable for a
# raw private key, so the keystore and its password are written to two 0600
# files in a private temp directory, handed to cast as ETH_KEYSTORE and
# ETH_PASSWORD (both paths) on the two commands that need them, and deleted on
# exit. Neither value is printed.
#
# Right before each send: eth_call must succeed on the current state,
# eth_estimateGas (+ buffer) gives the gas limit, and the fees are EIP-1559
# (maxFee = baseFeeMultiplier * latest base fee + priority fee). Never legacy:
# a legacy tx priced at eth_gasPrice can sit below the base fee forever.
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

if [ "$mode" != key ]; then keystore_json="" keystore_password=""; fi

check_foundry
mkdir -p "$out"

network="$(jq -r .network "$plan")"
chain_id="$(jq -r .chainId "$plan")"
[ "$chain_id" = "$(chain_id_of_network "$network")" ] || die "plan chain id $chain_id does not match config for $network"
rpc="${rpc:-$(rpc_of_network "$network")}"
explorer="$(cfg --arg n "$network" '.networks[$n].explorerTxUrl // ""' || true)"
buffer_pct="$(cfg .execution.gasLimitBufferPercent)"
max_gas="$(cfg .execution.maxTxGasLimit)"
fee_mult="$(cfg .execution.baseFeeMultiplier)"
receipt_timeout="$(cfg .execution.receiptTimeoutSeconds)"
poll="$(cfg .execution.receiptPollSeconds)"
sender="$(jq -r '.sender // ""' "$plan")"
count="$(jq '.transactions | length' "$plan")"

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

require_chain_id "$rpc" "$chain_id"

# ---------------------------------------------------------------- helpers
# Sets $nonce for sender $1. In key mode the loop tracks the expected nonce ($2)
# itself: a load-balanced RPC may answer from a node that has not seen our last
# receipt yet, so wait for it to catch up, and stop if the account moved on.
next_nonce() {
  local from="$1" expected="$2" latest pending waited=0
  while :; do
    latest="$("$CAST" nonce "$from" --block latest --rpc-url "$rpc")"
    if [ -z "$expected" ] || [ "$latest" -ge "$expected" ]; then break; fi
    [ "$waited" -lt "$receipt_timeout" ] || stop "RPC still reports nonce $latest for $from, expected $expected"
    sleep "$poll"
    waited=$((waited + poll))
  done
  if [ -n "$expected" ] && [ "$latest" -ne "$expected" ]; then
    stop "nonce of $from is $latest, expected $expected: something else sent from this account during the run"
  fi
  pending="$("$CAST" nonce "$from" --block pending --rpc-url "$rpc")"
  [ "$pending" -eq "$latest" ] ||
    stop "$from has $((pending - latest)) pending transaction(s) in the mempool; clear them before running"
  nonce="$latest"
}

# Sets $receipt for tx hash $1.
wait_receipt() {
  local hash="$1" waited=0
  until receipt="$("$CAST" receipt --async --json "$hash" --rpc-url "$rpc" 2>/dev/null)"; do
    [ "$waited" -lt "$receipt_timeout" ] || stop "no receipt for $hash after ${receipt_timeout}s; check it on an explorer before re-running (it may still be pending)"
    sleep "$poll"
    waited=$((waited + poll))
  done
}

# ---------------------------------------------------------------- loop
expected_nonce=""
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

  # Simulate on the current state, right before sending.
  if ! err="$("$CAST" call --from "$from" --value "$wei" "$to" "$data" --rpc-url "$rpc" 2>&1 >/dev/null)"; then
    printf '%s\n' "$err" >"$out/tx-$i.failure.txt"
    if [ "$mode" = impersonate ]; then
      "$CAST" call --trace --from "$from" --value "$wei" "$to" "$data" --rpc-url "$rpc" >>"$out/tx-$i.failure.txt" 2>&1 || true
    fi
    printf '%s\n' "$err" | tail -n 3 >&2
    stop "tx $i: eth_call reverts on the current state; nothing more was sent (details: tx-$i.failure.txt)"
  fi
  estimate="$("$CAST" estimate --from "$from" --value "$wei" "$to" "$data" --rpc-url "$rpc")" ||
    stop "tx $i: eth_estimateGas failed; nothing more was sent"
  [ "$estimate" -le "$max_gas" ] || stop "tx $i: estimated gas $estimate exceeds the per-tx cap $max_gas"
  gas_limit=$((estimate * (100 + buffer_pct) / 100))
  [ "$gas_limit" -le "$max_gas" ] || gas_limit="$max_gas"
  base_fee="$("$CAST" base-fee latest --rpc-url "$rpc")"
  priority_fee="$("$CAST" to-dec "$("$CAST" rpc eth_maxPriorityFeePerGas --rpc-url "$rpc" | tr -d '"')")"
  max_fee=$((base_fee * fee_mult + priority_fee))
  log "tx $i: eth_call ok; nonce $nonce, gas $estimate -> limit $gas_limit, maxFee $max_fee, priority $priority_fee (base $base_fee)"

  if [ "$dry_run" = true ]; then
    log "sender balance: $("$CAST" balance --ether "$from" --rpc-url "$rpc") ETH"
    outcome="DRY RUN, all checks passed for tx $i; nothing was signed or sent"
    log "DRY RUN: stopping before tx $i; nothing was signed or sent"
    exit 0
  fi

  fee_args=(--nonce "$nonce" --gas-limit "$gas_limit" --gas-price "$max_fee" --priority-gas-price "$priority_fee" --value "$wei")
  if [ "$mode" = impersonate ]; then
    hash="$("$CAST" send --unlocked --from "$from" --async "${fee_args[@]}" "$to" "$data" --rpc-url "$rpc")" ||
      stop "tx $i: send to the fork failed"
  else
    raw="$(ETH_KEYSTORE="$key_dir/keystore.json" ETH_PASSWORD="$key_dir/password" \
      "$CAST" mktx --chain "$chain_id" "${fee_args[@]}" "$to" "$data" --rpc-url "$rpc" 2>/dev/null)" ||
      stop "tx $i: signing failed; nothing more was sent"
    hash="$("$CAST" keccak "$raw")"
    log "tx $i: signed $hash; publishing"
    published="$("$CAST" publish --async "$raw" --rpc-url "$rpc")" ||
      stop "tx $i: publishing $hash failed; check it on an explorer before re-running"
    [ "$(lower "$published")" = "$(lower "$hash")" ] || stop "tx $i: RPC returned hash $published, signed $hash"
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
