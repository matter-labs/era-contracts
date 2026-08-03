#!/bin/bash
# Replay a v31 DEPLOY BUNDLE (see `pack-deploy-bundle.sh`) and verify the result
# with PUVT (`ecosystem verify-upgrade`).
#
# This is the CONSUME half of the generate/consume split: it needs no Solidity
# build, no foundry-zksync and no upgrade regeneration — the bundle already
# carries the compiled init code, so all that is required is this checkout (for
# the env configs + `AllContractsHashes.json`) and `protocol_ops`. That is what
# makes "deploy the contracts and run PUVT yourself" a self-contained operation
# for anyone holding the CI artifact.
#
#   # rehearse on a throw-away fork (impersonates every signer, signs nothing)
#   ./replay-bundle-and-verify.sh --bundle <dir> --fork-url <l1-rpc>
#
#   # verify a chain the bundle was already broadcast to (no replay)
#   ./replay-bundle-and-verify.sh --bundle <dir> --rpc <l1-rpc> --verify-only
#
#   # broadcast for real, then verify (needs the deployer key)
#   ./replay-bundle-and-verify.sh --bundle <dir> --rpc <l1-rpc> --key 0x…
#
# The fork height, env, deployer and zk-governance commit come from the bundle's
# `bundle-metadata.json`, so the same command works for any env/bundle.

set -euo pipefail

# shellcheck source=./upgrade-bundle-lib.sh
source "$(dirname "$0")/upgrade-bundle-lib.sh"

BUNDLE=""
FORK_URL=""
RPC=""
DEPLOYER_KEY=""
VERIFY_ONLY=0
usage() {
  echo "usage: $0 --bundle <dir> (--fork-url <l1-rpc> | --rpc <rpc>) [--key <0xhex>] [--verify-only]" >&2
  exit 1
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --fork-url) FORK_URL="$2"; shift 2 ;;
    --rpc) RPC="$2"; shift 2 ;;
    --key) DEPLOYER_KEY="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$BUNDLE" ]] || usage
[[ -n "$FORK_URL" || -n "$RPC" ]] || usage
if [[ -n "$FORK_URL" && -n "$RPC" ]]; then
  echo "pass either --fork-url (start a fork) or --rpc (use an existing chain), not both" >&2
  exit 1
fi
[[ -f "$BUNDLE/bundle-metadata.json" ]] || { echo "not a deploy bundle (no bundle-metadata.json): $BUNDLE" >&2; exit 1; }

meta() { jq -r "$1 // empty" "$BUNDLE/bundle-metadata.json"; }
ENV="$(meta .env)"
DEPLOYER="$(meta .deployer_address)"
FORK_BLOCK="$(meta .l1.forked_at_block)"
BUNDLE_COMMIT="$(meta .contracts_commit)"
BUNDLE_HASHES_SHA="$(meta .all_contracts_hashes_sha256)"
ZK_GOV_COMMIT="${ZK_GOVERNANCE_COMMIT:-$(meta .zk_governance_commit)}"
ZK_GOV_COMMIT="${ZK_GOV_COMMIT:-cc7c76d}"

L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
REPO_ROOT="$(cd "$L1_CONTRACTS_DIR"/.. && pwd)"
PERMANENT_VALUES="$L1_CONTRACTS_DIR/upgrade-envs/permanent-values/$ENV.toml"
V31_INPUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/$ENV.toml"
for f in "$PERMANENT_VALUES" "$V31_INPUT"; do
  [[ -f "$f" ]] || { echo "config not found: $f (is this the right checkout for env '$ENV'?)" >&2; exit 1; }
done

echo "Env:          $ENV"
echo "Bundle:       $BUNDLE"
echo "Deployer:     $DEPLOYER"

# PUVT identifies each deployed contract by matching its code against the
# `AllContractsHashes.json` of the CHECKOUT. If that file differs from the one
# the bundle was built against, deployments stop being recognised (they are
# skipped as "stale") and the run's verdict is meaningless — so say so loudly.
LOCAL_HASHES_SHA="$(sha256sum "$REPO_ROOT/AllContractsHashes.json" | cut -d' ' -f1)"
if [[ -n "$BUNDLE_HASHES_SHA" && "$LOCAL_HASHES_SHA" != "$BUNDLE_HASHES_SHA" ]]; then
  echo "WARNING: AllContractsHashes.json differs from the bundle's." >&2
  echo "         bundle: $BUNDLE_HASHES_SHA (commit $BUNDLE_COMMIT)" >&2
  echo "         local:  $LOCAL_HASHES_SHA" >&2
  echo "         PUVT will not recognise the deployed bytecode. Check out $BUNDLE_COMMIT" >&2
  echo "         (or pass --contracts-commit to verify-upgrade) before trusting the result." >&2
fi

_PO_DIR="$REPO_ROOT/protocol-ops"
PROTOCOL_OPS="$(locate_protocol_ops "$_PO_DIR")"
echo "protocol_ops: $PROTOCOL_OPS"

# The replay fork gets its own port (generate fork port + 1) so a bundle replay
# and a generate rehearsal of the same env can run side by side.
KEEP_ANVIL="${KEEP_ANVIL:-0}"
cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    if [[ "$KEEP_ANVIL" == "1" ]]; then
      echo "Leaving anvil (pid $ANVIL_PID) running on $RPC (KEEP_ANVIL=1)"
      return
    fi
    echo "Stopping anvil (pid $ANVIL_PID)..."
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

WORK="$BUNDLE/replay"
mkdir -p "$WORK"

if [[ -n "$FORK_URL" ]]; then
  PORT=$(( $(env_anvil_port "$ENV") + 1 ))
  RPC="http://localhost:$PORT"
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "=== Step 0: reusing anvil on $RPC ==="
  else
    echo "=== Step 0: anvil fork on port $PORT ==="
    # Pin to the height the bundle was computed against: a later state may have
    # moved ownership off the deployer or started the upgrade timer, either of
    # which makes the replay revert.
    if [[ -z "$FORK_BLOCK" ]]; then
      echo "WARNING: the bundle records no fork height — forking at chain tip." >&2
      echo "         If the upgrade is already live the replay will revert; re-pack the" >&2
      echo "         bundle with FORKED_AT_BLOCK set, or fork manually and pass --rpc." >&2
    fi
    start_anvil_fork "$PORT" "$FORK_URL" "$FORK_BLOCK" "$WORK/anvil.log"
  fi
fi
echo "L1 RPC:       $RPC"
GW_RPC_URL="${GW_RPC_URL:-$RPC}"

MANIFEST="$BUNDLE/prepare/manifest.json"
EXECUTED="$WORK/executed.json"
TXLOG="$WORK/transactions.txt"

if [[ "$VERIFY_ONLY" == "1" ]]; then
  echo "=== Steps 1-2: SKIPPED (--verify-only) ==="
else
  if [[ -n "$FORK_URL" ]]; then
    echo "=== Step 1: fund every bundle signer (fork only) ==="
    BRIDGEHUB="$(read_toml_str "$V31_INPUT" bridgehub_proxy_address)"
    [[ -n "$BRIDGEHUB" ]] || { echo "bridgehub_proxy_address not found in $V31_INPUT" >&2; exit 1; }
    ZK_ASSET_ID="$(read_toml_str "$PERMANENT_VALUES" zk_token_asset_id)"
    [[ -n "$ZK_ASSET_ID" ]] || { echo "zk_token_asset_id not found in $PERMANENT_VALUES" >&2; exit 1; }
    fund_bundle_targets "$RPC" "$BRIDGEHUB" "$ZK_ASSET_ID" "$(env_has_gateway "$PERMANENT_VALUES")" \
      "$MANIFEST" "$BUNDLE/ecosystem.toml" "$DEPLOYER"
    # Pin the base fee to 1 gwei so the EIP-1559 escalation doesn't cause
    # MsgValueTooLow on priority deposit txs whose mintValue was computed at
    # prepare time with a lower gas price.
    cast rpc anvil_setNextBlockBaseFeePerGas 0x3B9ACA00 --rpc-url "$RPC" >/dev/null
  fi

  echo "=== Step 2: upgrade-broadcast ==="
  rm -f "$TXLOG"
  broadcast_args=(
    ecosystem upgrade-broadcast
    --manifest "$MANIFEST"
    --l1-rpc-url "$RPC"
    --out "$EXECUTED"
  )
  if [[ -n "$DEPLOYER_KEY" ]]; then
    # Real signing: only the bundles we hold a key for. The governance ceremony
    # bundles are executed by their own multisig, so they are skipped.
    broadcast_args+=(--key "${DEPLOYER}=${DEPLOYER_KEY}" --skip-unkeyed)
  else
    # Fork rehearsal: anvil impersonates every signer, including governance, so
    # the whole manifest replays and PUVT sees the post-ceremony state.
    broadcast_args+=(--unlocked)
  fi
  "$PROTOCOL_OPS" "${broadcast_args[@]}"
fi

echo "=== Step 3: verify-upgrade (PUVT) ==="
# PUVT resolves CREATE2 deployments from tx hashes. Feed it this replay's log
# plus (when present) the committed real-network log for this env, so deployments
# that already happened on the real chain are recognised too.
COMBINED_TXLOG="$WORK/transactions.combined.txt"
: > "$COMBINED_TXLOG"
REAL_TXLOG="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/output/$ENV/transactions.txt"
[[ -f "$REAL_TXLOG" ]] && cat "$REAL_TXLOG" >> "$COMBINED_TXLOG"
[[ -f "$TXLOG" ]] && cat "$TXLOG" >> "$COMBINED_TXLOG"
"$PROTOCOL_OPS" ecosystem verify-upgrade \
  --env "$ENV" \
  --ecosystem-toml "$BUNDLE/ecosystem.toml" \
  --l1-rpc-url "$RPC" \
  --gw-rpc-url "$GW_RPC_URL" \
  --transactions-log "$COMBINED_TXLOG" \
  --zk-governance-commit "$ZK_GOV_COMMIT"

echo "=== Done ==="
