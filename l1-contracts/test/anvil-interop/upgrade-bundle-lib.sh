#!/bin/bash
# Shared helpers for the v31 ecosystem-upgrade fork flows.
#
# Sourced by:
#   - `regen-and-verify.sh`        — GENERATE: fork, prepare, replay, PUVT.
#   - `replay-bundle-and-verify.sh` — CONSUME: replay a already-generated deploy
#                                     bundle onto a fork (or real L1) and PUVT it.
#
# Both need the same primitives (read a scalar out of the env TOMLs, find the
# `protocol_ops` binary, start a pinned anvil fork, fund every bundle target),
# so they live here instead of being copy-pasted between the two.
#
# This file only defines functions — sourcing it has no side effects.

# Read a top-level scalar string (`key = "value"`) out of a TOML file.
# $1 = file, $2 = key. Prints the empty string when the key is absent.
read_toml_str() {
  python3 -c "
import re, sys
m = re.search(r'^${2}\s*=\s*[\"\']([^\"\']+)', open('${1}').read(), re.MULTILINE)
print(m.group(1) if m else '', end='')
"
}

# Read a top-level scalar integer (`key = 123`) out of a TOML file.
# Matches the digits AFTER the `=` so keys that themselves contain digits
# (`l1_chain_id`) don't self-match. Prints the empty string when absent.
read_toml_int() {
  sed -nE "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$1" | head -1
}

# Base anvil port for an env's GENERATE fork. Each env gets a distinct port so
# stage/testnet/mainnet rehearsals can run in parallel without colliding (and a
# KEEP_ANVIL fork of one env is never reused by another).
#
# The CONSUME flow (`replay-bundle-and-verify.sh`) uses base+1, so a bundle
# replay can run next to a generate rehearsal of the same env.
env_anvil_port() {
  case "$1" in
    stage) echo 29545 ;;
    testnet) echo 29547 ;;
    mainnet) echo 29549 ;;
    battlechain) echo 29551 ;;
    *)
      echo "Unknown env '$1' (expected: stage | testnet | mainnet | battlechain)" >&2
      echo "Add a port for it here if it needs its own fork." >&2
      return 1
      ;;
  esac
}

# Run PUVT (`ecosystem verify-upgrade`) with the given args.
#
# With VERIFY_NONFATAL=1 a non-zero exit is reported as a warning instead of
# aborting. That is for ecosystems whose topology the mainnet-oriented PUVT does
# not model — e.g. legacy-`Governance.sol`-owned ones (no ProtocolUpgradeHandler,
# so the PUH/zk-governance provenance checks don't apply) or single-chain ones
# (PUVT's Era-diamond fee-param check compares against a chain that isn't
# registered). The calldata is produced by the prepare regardless, so this lets a
# run publish its artifacts while still printing the full PUVT output for review.
# Use it deliberately, per env — never to paper over a PUH-governed env's errors.
# $1 = protocol_ops path; remaining args are forwarded verbatim.
run_verify_upgrade() {
  local protocol_ops="$1"; shift
  local rc=0
  "$protocol_ops" ecosystem verify-upgrade "$@" || rc=$?
  if [[ "$rc" != "0" ]]; then
    if [[ "${VERIFY_NONFATAL:-0}" == "1" ]]; then
      echo "::warning::verify-upgrade (PUVT) exited $rc — treated as NON-FATAL (VERIFY_NONFATAL=1)." >&2
      echo "    Review the PUVT output above; the calldata artifacts were still produced." >&2
      return 0
    fi
    return "$rc"
  fi
}

# Locate the protocol_ops binary. Prefer the local debug build (devs iterate on
# this), then the release build, then anything on PATH (the Docker image puts it
# on PATH via /contracts/protocol-ops/).
# $1 = repo's protocol-ops directory. Prints the resolved path.
locate_protocol_ops() {
  local po_dir="$1"
  if [[ -x "$po_dir/target/debug/protocol_ops" ]]; then
    echo "$po_dir/target/debug/protocol_ops"
  elif [[ -x "$po_dir/target/release/protocol_ops" ]]; then
    echo "$po_dir/target/release/protocol_ops"
  elif [[ -x "$po_dir/protocol_ops" ]]; then
    echo "$po_dir/protocol_ops"
  elif command -v protocol_ops >/dev/null 2>&1; then
    command -v protocol_ops
  else
    echo "protocol_ops binary not found — build it with 'cd protocol-ops && cargo build --release'" >&2
    return 1
  fi
}

# Start an anvil fork and wait for it to serve.
# $1 = port, $2 = fork url, $3 = fork block (may be empty = tip), $4 = log path.
# Exports ANVIL_PID for the caller's cleanup trap.
start_anvil_fork() {
  local port="$1" fork_url="$2" fork_block="$3" log="$4"
  local anvil_args=(
    --port "$port"
    --auto-impersonate
    --disable-block-gas-limit
    --gas-price 1000000000
    --fork-url "$fork_url"
  )
  # Optional block pin. Needed when the live chain is mid- or post-upgrade:
  # forking the tip would inherit an already-applied stage (e.g. a started
  # GovernanceUpgradeTimer, or ownership already handed off from the deployer),
  # making the replay revert. Pin to a pre-upgrade block for a clean state.
  if [[ -n "$fork_block" ]]; then
    echo "    pinning fork to block $fork_block"
    anvil_args+=(--fork-block-number "$fork_block")
  fi
  anvil "${anvil_args[@]}" >"$log" 2>&1 &
  ANVIL_PID=$!
  local rpc="http://localhost:$port"
  local _
  for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  cast chain-id --rpc-url "$rpc" >/dev/null || { echo "anvil failed to start (see $log)" >&2; return 1; }
}

# Give every bundle signer the ETH (gas) and ZK (base-token burn) it needs, and
# pre-register the ZK asset id so gateway priority deposits pass.
#
# $1 = rpc, $2 = bridgehub, $3 = zk asset id, $4 = has_gateway (0|1),
# $5 = manifest.json, $6 = ecosystem.toml, $7 = deployer address.
#
# On the deployer-EOA-with-PUH-as-owner split the manifest targets are the
# deployer EOA, the security council EOA, AND PUH itself (PUH lands in the list
# because it owns a CTM/ProxyAdmin and the wrap script broadcasts the
# corresponding accept-ownership / transferOwnership txs from PUH).
fund_bundle_targets() {
  local rpc="$1" bridgehub="$2" zk_asset_id="$3" has_gateway="$4"
  local manifest="$5" ecosystem_toml="$6" deployer="$7"
  # 1e30 wei
  local fund_amount="1000000000000000000000000000000"

  local ar ntv zk_token
  ar=$(cast call "$bridgehub" "assetRouter()(address)" --rpc-url "$rpc")
  ntv=$(cast call "$ar" "nativeTokenVault()(address)" --rpc-url "$rpc")
  zk_token=$(cast call "$ntv" "tokenAddress(bytes32)(address)" "$zk_asset_id" --rpc-url "$rpc")
  echo "AR=$ar"
  echo "NTV=$ntv"
  echo "ZK_TOKEN=$zk_token"
  cast rpc anvil_setBalance "$ntv" 0x21e19e0c9bab2400000 --rpc-url "$rpc" >/dev/null

  local targets target
  targets=$(jq -r '.bundles[].target' "$manifest" | sort -u)
  echo "Bundle targets:"
  echo "$targets" | sed 's/^/  /'
  for target in $targets; do
    cast rpc anvil_setBalance "$target" 0x21e19e0c9bab2400000 --rpc-url "$rpc" >/dev/null
    if [[ "$has_gateway" == "1" ]]; then
      # Gateway-enabled env: ZK is the NTV-mintable new-GW base token and bundle
      # 5's GW priority tx burns it — funding must succeed.
      echo "  bridgeMint($target, $fund_amount)"
      cast send --from "$ntv" --unlocked "$zk_token" \
        "bridgeMint(address,uint256)" "$target" "$fund_amount" \
        --rpc-url "$rpc" >/dev/null
    else
      # Gateway-less env: the ZK token is L1-native (a plain ERC20, not
      # NTV-mintable, so bridgeMint reverts Unauthorized(NTV)) and unnecessary —
      # no GW priority tx burns ZK. Tolerate the revert; the ETH gas funding
      # above is all the fork replay needs.
      echo "  bridgeMint($target, $fund_amount) [best-effort]"
      cast send --from "$ntv" --unlocked "$zk_token" \
        "bridgeMint(address,uint256)" "$target" "$fund_amount" \
        --rpc-url "$rpc" >/dev/null 2>&1 || true
    fi
  done

  # Register the ZK token assetId in L1AssetTracker so bundle 5's GW priority
  # deposits (which burn ZK as the new-GW base token) pass the
  # `_requireRegistered` check on `handleChainBalanceIncreaseOnL1`. In production
  # this registration lands as stage-2 call 6 (`registerLegacyToken`), but the
  # bundles are replayed BEFORE governance, so we prime it here directly.
  # `registerLegacyToken` is public — anyone can call it.
  local asset_tracker
  asset_tracker=$(awk -F'"' '/^asset_tracker_proxy_addr[ \t]*=/{print $2; exit}' "$ecosystem_toml")
  if [ -n "$asset_tracker" ]; then
    echo "  registerLegacyToken($zk_asset_id) on $asset_tracker"
    cast send "$asset_tracker" "registerLegacyToken(bytes32)" "$zk_asset_id" \
      --from "$deployer" --unlocked --rpc-url "$rpc" >/dev/null || true
  else
    echo "  WARNING: asset_tracker_proxy_addr not found in $ecosystem_toml — skipping registerLegacyToken"
  fi
}

# Does this env bring up a new Gateway? Gateway-enabled envs (stage, mainnet)
# have a `[new_gateway]` table in permanent-values; their ZK token is the new-GW
# base token (NTV-mintable) and bundle 5's GW priority tx burns it, so ZK
# funding MUST succeed. Gateway-less envs (testnet) omit the table; their ZK
# token is L1-native (a plain ERC20, not NTV-mintable → bridgeMint reverts) and
# no GW priority tx burns ZK, so the funding is both impossible and unnecessary.
# $1 = permanent-values path. Prints 1 or 0.
env_has_gateway() {
  if grep -qE '^\[new_gateway\]' "$1"; then echo 1; else echo 0; fi
}
