#!/bin/bash
# Regenerate an ecosystem upgrade artifact for one environment against a fresh anvil fork of
# its L1, rehearse the emitted bundles on that fork, and run PUVT over the result.
#
# Replaces the former `regen-and-verify-stage.sh`, which hardcoded `stage` in four places
# (bridgehub, `--env`, the ZK asset id, the output dir) and still wrote into the *v31*
# output directory after the release directory moved. Everything env-specific now comes from
# `upgrade-envs/permanent-values/<env>.toml` and `upgrade-envs/v0.33.0-atomic-interop/<env>.toml`,
# so the same script serves testnet, stage and mainnet.
#
# Dropped along with it: the ZK-token funding loop, which minted the base token to every
# bundle target so Gateway-bound L1->L2 priority txs could pay their `mintValue`. This release
# brings up no Gateway, so no bundle carries such a tx. Restore it if a future release does.
#
# Required env vars:
#   L1_FORK_URL                          — L1 RPC URL to fork
#   DEPLOYER_PK=<0xhex>                  — broadcast signer's private key, OR
#   DEPLOYER_PK_FILE=<path>              — file holding the same (trimmed)
#   GW_RPC_URL                           — Gateway RPC; PUVT reads GW-side state through it.
#                                          Only needed when PUVT runs (see SKIP_PUVT).
#
# Usage:
#   DEPLOYER_PK_FILE=~/.deployer_pk L1_FORK_URL=https://… ./regen-upgrade-calldata.sh testnet
#
# Iteration flags:
#   SKIP_PREPARE=1    reuse the existing <out>/prepare (skip the forge scripts)
#   SKIP_REHEARSAL=1  reuse <out>/fork-rehearsal/executed.json (skip funding + bundle replay)
#   SKIP_PUVT=1       stop after the rehearsal
#   KEEP_ANVIL=1      leave the fork anvil up for ad-hoc `cast` probes
#   PORT=<n>          fork anvil port (default 29645; override when sharing a box)
#   FORK_BLOCK=<n>    pin the fork (see Step 0)

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
import tomllib
d = tomllib.load(open('$PERMANENT_VALUES', 'rb'))
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

# zk-governance commit whose AllContractsHashes.json PUVT verifies PUH/Guardians bytecodes
# against. Only consulted on PUH-governed envs.
ZK_GOV_COMMIT="${ZK_GOVERNANCE_COMMIT:-3e516c5}"

SKIP_PUVT="${SKIP_PUVT:-0}"
if [[ "$SKIP_PUVT" != "1" && -z "${GW_RPC_URL:-}" ]]; then
  echo "GW_RPC_URL is required for the PUVT step (or set SKIP_PUVT=1)" >&2
  exit 1
fi

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
  # FORK_BLOCK pins the fork. Two cases need it: the live chain is mid-upgrade (forking the
  # tip would inherit an already-armed GovernanceUpgradeTimer), or this env's contracts are
  # already deployed from a previous run of this script — CREATE2 is idempotent, so forking
  # tip finds every target occupied and the prepare cannot reproduce the artifact. Pin to a
  # block before those deploys landed.
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
  # No --redeploy-zk-governance: this release ships no new zk-governance set, so the live
  # ProtocolUpgradeHandler is left alone.
  "$PROTOCOL_OPS" ecosystem upgrade-prepare-all \
    --env "$ENV_NAME" \
    --bridgehub "$BRIDGEHUB" \
    --l1-rpc-url "$RPC" \
    --deployer-address "$DEPLOYER" \
    --out "$OUT/prepare" \
    --additional-args=--memory-limit=536870912
fi

# The committed `transactions.txt` holds REAL-network hashes only. The rehearsal mines its
# own, which exist solely on this local fork, so they go to a git-ignored dir and are never
# merged into the committed log. PUVT reads both.
FORK_DIR="$OUT/fork-rehearsal"

if [[ "${SKIP_REHEARSAL:-0}" == "1" && -f "$FORK_DIR/executed.json" ]]; then
  echo "=== Step 2: SKIPPED (SKIP_REHEARSAL=1) ==="
else
  echo "=== Step 2: fork rehearsal — replay every prepare bundle under impersonation ==="
  rm -rf "$FORK_DIR"; mkdir -p "$FORK_DIR"
  for TARGET in $(python3 -c "
import json
m = json.load(open('$OUT/prepare/manifest.json'))
print('\n'.join(sorted({b['target'] for b in m['bundles']})))
"); do
    echo "  funding $TARGET"
    cast rpc anvil_setBalance "$TARGET" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
  done
  # Pin the base fee to 1 gwei so EIP-1559 escalation can't push a tx's cost above a value
  # computed at prepare time.
  cast rpc anvil_setNextBlockBaseFeePerGas 0x3B9ACA00 --rpc-url "$RPC" >/dev/null
  "$PROTOCOL_OPS" ecosystem upgrade-broadcast \
    --manifest "$OUT/prepare/manifest.json" \
    --l1-rpc-url "$RPC" \
    --unlocked \
    --out "$FORK_DIR/executed.json"
fi

if [[ "$SKIP_PUVT" == "1" ]]; then
  echo "=== Step 3: SKIPPED (SKIP_PUVT=1) ==="
  echo "=== Done: $OUT/ecosystem.toml ==="
  exit 0
fi

echo "=== Step 3: verify-upgrade (PUVT) ==="
# Feed PUVT the committed real-network log followed by this run's fork log, so CREATE2
# provenance resolves whether a contract was deployed for real or only on the fork.
COMBINED_TXLOG="$FORK_DIR/transactions.combined.txt"
: > "$COMBINED_TXLOG"
[[ -f "$OUT/transactions.txt" ]] && cat "$OUT/transactions.txt" >> "$COMBINED_TXLOG"
[[ -f "$FORK_DIR/transactions.txt" ]] && cat "$FORK_DIR/transactions.txt" >> "$COMBINED_TXLOG"
"$PROTOCOL_OPS" ecosystem verify-upgrade \
  --env "$ENV_NAME" \
  --ecosystem-toml "$OUT/ecosystem.toml" \
  --l1-rpc-url "$RPC" \
  --gw-rpc-url "$GW_RPC_URL" \
  --transactions-log "$COMBINED_TXLOG" \
  --zk-governance-commit "$ZK_GOV_COMMIT"

echo "=== Done ==="
echo "Artifact:    $OUT/ecosystem.toml"
echo "Verify cmds: $OUT/extra-verification-logs.txt"
echo
echo "Next: broadcast the deployer bundle to the real L1, then emit the transaction-simulator"
echo "scenario. Both are documented in $OUT/README.md."
