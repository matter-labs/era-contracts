#!/bin/bash
# Regenerate a v33 ecosystem upgrade artifact for one environment against a fresh anvil
# fork of its L1, then rehearse the emitted bundles on that fork.
#
# This is the v33 counterpart of `regen-and-verify-stage.sh`. Two deliberate differences:
#
#   * **Env-parameterised.** Everything env-specific (bridgehub, CTM list, governance kind,
#     CREATE2 salts) is read from `upgrade-envs/permanent-values/<env>.toml` and
#     `upgrade-envs/v0.33.0-atomic-interop/<env>.toml`, so the same script serves testnet,
#     stage and mainnet.
#   * **No PUVT.** `ecosystem verify-upgrade` only implements the v31 verifier
#     (`upgrade_verification/versions/v31/`); there is no v33 element set, so running it
#     against a v33 artifact would check the wrong expectations. Validation here is the
#     fork rehearsal below plus the transaction-simulator scenario emitted by
#     `ecosystem governance-toml-to-simulator` (see the output dir's README).
#
# Required env vars:
#   L1_FORK_URL                          — L1 RPC URL to fork
#   DEPLOYER_PK=<0xhex>                  — broadcast signer's private key, OR
#   DEPLOYER_PK_FILE=<path>              — file holding the same (trimmed)
#
# Usage:
#   DEPLOYER_PK_FILE=~/.deployer_pk L1_FORK_URL=https://… ./regen-upgrade-calldata.sh testnet
#
# Iteration flags:
#   SKIP_PREPARE=1    reuse the existing <out>/prepare (skip the forge scripts)
#   SKIP_REHEARSAL=1  stop after the prepare
#   KEEP_ANVIL=1      leave the fork anvil up for ad-hoc `cast` probes
#   PORT=<n>          fork anvil port (default 29645; override when sharing a box)

set -euo pipefail

ENV_NAME="${1:-}"
if [[ -z "$ENV_NAME" ]]; then
  echo "usage: $0 <env>   (e.g. testnet, stage, mainnet)" >&2
  exit 1
fi
if [[ -z "${L1_FORK_URL:-}" ]]; then
  echo "L1_FORK_URL is required" >&2
  exit 1
fi

PORT="${PORT:-29645}"
RPC="http://localhost:$PORT"
L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
UPGRADE_ENV_DIR="$L1_CONTRACTS_DIR/upgrade-envs/v0.33.0-atomic-interop"
PERMANENT_VALUES="$L1_CONTRACTS_DIR/upgrade-envs/permanent-values/$ENV_NAME.toml"
OUT="$UPGRADE_ENV_DIR/output/$ENV_NAME"

for f in "$PERMANENT_VALUES" "$UPGRADE_ENV_DIR/$ENV_NAME.toml"; do
  [[ -f "$f" ]] || { echo "missing env file: $f" >&2; exit 1; }
done

# Read the bridgehub from permanent-values rather than hardcoding it, so this script cannot
# drift from the source of truth when an env is re-pointed.
BRIDGEHUB="$(python3 -c "
import tomllib,sys
d=tomllib.load(open('$PERMANENT_VALUES','rb'))
print(d['core_contracts']['bridgehub_proxy_addr'])
")"
echo "Env:          $ENV_NAME"
echo "Bridgehub:    $BRIDGEHUB"

# The deployer EOA is derived from the PK at call time; we deliberately don't read it from
# the env config, whose `owner_address` is governance (a contract), not a signable EOA.
if [[ -z "${DEPLOYER_PK:-}" ]]; then
  if [[ -n "${DEPLOYER_PK_FILE:-}" ]]; then
    [[ -f "$DEPLOYER_PK_FILE" ]] || { echo "DEPLOYER_PK_FILE=$DEPLOYER_PK_FILE does not exist" >&2; exit 1; }
    DEPLOYER_PK="$(tr -d '[:space:]' < "$DEPLOYER_PK_FILE")"
  else
    echo "Set either DEPLOYER_PK=<0xhex> or DEPLOYER_PK_FILE=<path>" >&2
    exit 1
  fi
fi
DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"
echo "Deployer EOA: $DEPLOYER"

# `bytecode_hash=none` / `cbor_metadata=false`. Without it the compiler embeds a metadata
# hash that varies with absolute paths, every CREATE2 address shifts, and the artifact stops
# being reproducible on another machine.
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-anvil-interop}"
echo "Profile:      $FOUNDRY_PROFILE"

_PO_DIR="$(cd "$(dirname "$0")"/../../../protocol-ops && pwd)"
if [[ -x "$_PO_DIR/target/release/protocol_ops" ]]; then
  PROTOCOL_OPS="$_PO_DIR/target/release/protocol_ops"
elif [[ -x "$_PO_DIR/target/debug/protocol_ops" ]]; then
  PROTOCOL_OPS="$_PO_DIR/target/debug/protocol_ops"
elif command -v protocol_ops >/dev/null 2>&1; then
  PROTOCOL_OPS="$(command -v protocol_ops)"
else
  echo "protocol_ops not found — build it with 'cd protocol-ops && cargo build --release'" >&2
  exit 1
fi
echo "protocol_ops: $PROTOCOL_OPS"

KEEP_ANVIL="${KEEP_ANVIL:-0}"
cleanup() {
  if [[ "$KEEP_ANVIL" == "1" ]]; then
    echo "Leaving anvil (pid ${ANVIL_PID:-?}) on $RPC (KEEP_ANVIL=1)"
    return
  fi
  # Only ever kill the anvil this script started: other sessions may have their own.
  if [[ -n "${ANVIL_PID:-}" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$OUT"

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "=== Step 0: reusing anvil already serving $RPC ==="
else
  echo "=== Step 0: anvil fork on port $PORT ==="
  # FORK_BLOCK pins the fork when the live chain is mid-upgrade: forking the tip would
  # inherit an already-armed GovernanceUpgradeTimer and make the rehearsal revert.
  FORK_BLOCK_ARG=()
  [[ -n "${FORK_BLOCK:-}" ]] && FORK_BLOCK_ARG=(--fork-block-number "$FORK_BLOCK")
  anvil --port "$PORT" --auto-impersonate --disable-block-gas-limit --gas-price 1000000000 \
    --fork-url "$L1_FORK_URL" "${FORK_BLOCK_ARG[@]}" >"$OUT/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 40); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
  cast chain-id --rpc-url "$RPC" >/dev/null || { echo "anvil failed to start; see $OUT/anvil.log"; exit 1; }
fi

if [[ "${SKIP_PREPARE:-0}" == "1" && -f "$OUT/prepare/manifest.json" ]]; then
  echo "=== Step 1: SKIPPED (SKIP_PREPARE=1) ==="
else
  echo "=== Step 1: ecosystem upgrade-prepare-all (several minutes) ==="
  # No --redeploy-zk-governance: v33 ships no new zk-governance set, so the live
  # ProtocolUpgradeHandler is left alone.
  "$PROTOCOL_OPS" ecosystem upgrade-prepare-all \
    --env "$ENV_NAME" \
    --bridgehub "$BRIDGEHUB" \
    --l1-rpc-url "$RPC" \
    --deployer-address "$DEPLOYER" \
    --out "$OUT/prepare" \
    --additional-args=--memory-limit=536870912
fi

if [[ "${SKIP_REHEARSAL:-0}" == "1" ]]; then
  echo "=== Step 2: SKIPPED (SKIP_REHEARSAL=1) ==="
  echo "=== Done: $OUT/ecosystem.toml ==="
  exit 0
fi

echo "=== Step 2: fork rehearsal — replay every prepare bundle under impersonation ==="
# The committed `transactions.txt` holds REAL-network hashes only. This rehearsal mines its
# own, which exist solely on this local fork, so they go to a git-ignored dir and are never
# merged into the committed log.
FORK_DIR="$OUT/fork-rehearsal"
rm -rf "$FORK_DIR"; mkdir -p "$FORK_DIR"
for TARGET in $(python3 -c "
import json
m=json.load(open('$OUT/prepare/manifest.json'))
print('\n'.join(sorted({b['target'] for b in m['bundles']})))
"); do
  echo "  funding $TARGET"
  cast rpc anvil_setBalance "$TARGET" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
done
# Pin the base fee to 1 gwei so EIP-1559 escalation can't push a priority deposit's cost
# above the mintValue computed at prepare time.
cast rpc anvil_setNextBlockBaseFeePerGas 0x3B9ACA00 --rpc-url "$RPC" >/dev/null
"$PROTOCOL_OPS" ecosystem upgrade-broadcast \
  --manifest "$OUT/prepare/manifest.json" \
  --l1-rpc-url "$RPC" \
  --unlocked \
  --out "$FORK_DIR/executed.json"

echo "=== Done ==="
echo "Artifact:      $OUT/ecosystem.toml"
echo "Verify cmds:   $OUT/extra-verification-logs.txt"
echo
echo "Next: broadcast the deployer bundle to the real L1, then emit + rehearse the"
echo "transaction-simulator scenario. Both are documented in $OUT/README.md."
echo
echo "NOTE: governance stages 0 and 1 cannot both replay on one fork — stage 0 arms a"
echo "GovernanceUpgradeTimer that stage 1's checkDeadline() only clears once its"
echo "INITIAL_DELAY has elapsed. The simulator scenario handles this via timeIncrease."
