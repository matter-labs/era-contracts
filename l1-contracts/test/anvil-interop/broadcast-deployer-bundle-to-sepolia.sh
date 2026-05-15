#!/bin/bash
# Broadcast the v31 stage deployer bundle (bundle 04 from
# `regen-and-verify-stage.sh`) to real Sepolia.
#
# Why: the tx-simulator's local sim runs `getCode(tx.to)` on every governance
# tx before sending, and stage 0's `startTimer(...)` (and a few stage-1/2
# calls) target contracts the deployer bundle CREATE2-deploys. Until those
# deploys actually hit Sepolia, the simulator fails with
# `Transaction calls ... EOA with non-empty calldata`.
#
# We only broadcast the CREATE2-factory txs from bundle 04. The remaining
# bundle 04 txs (Gateway L1→L2 priority txs + their ZK approves) require
# the deployer EOA to hold ZK base token on Sepolia, which it does not —
# but the tx-simulator's L1-side checks don't need the GW-side L2 state, so
# skipping those keeps the broadcast under "what the simulator actually
# needs" without spending real ZK.
#
# Required env vars:
#   DEPLOYER_PK=<0xhex>        — broadcast signer's private key, OR
#   DEPLOYER_PK_FILE=<path>    — file holding the same (trimmed)
#   L1_RPC_URL=<real-sepolia>  — Sepolia RPC URL
#
# Usage:
#   DEPLOYER_PK_FILE=~/.test_pk \
#   L1_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<key> \
#   ./broadcast-deployer-bundle-to-sepolia.sh

set -euo pipefail

if [[ -z "${L1_RPC_URL:-}" ]]; then
  echo "L1_RPC_URL is required (point at real Sepolia)" >&2
  exit 1
fi

if [[ -z "${DEPLOYER_PK:-}" ]]; then
  if [[ -n "${DEPLOYER_PK_FILE:-}" ]]; then
    [[ -f "$DEPLOYER_PK_FILE" ]] || { echo "DEPLOYER_PK_FILE=$DEPLOYER_PK_FILE does not exist" >&2; exit 1; }
    DEPLOYER_PK="$(tr -d '[:space:]' < "$DEPLOYER_PK_FILE")"
  else
    echo "Set DEPLOYER_PK=<0xhex> or DEPLOYER_PK_FILE=<path>" >&2
    exit 1
  fi
fi

DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"
echo "Deployer EOA: $DEPLOYER"

# Read regen artifacts from the same env-scoped location regen-and-verify-stage.sh writes to.
L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
OUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/output/stage/regen"
PREPARE_DIR="$OUT/prepare"
PROTOCOL_OPS="$(cd "$(dirname "$0")"/../../../protocol-ops && pwd)/target/debug/protocol_ops"

# Locate the deployer bundle in $PREPARE_DIR. The filename suffix is the
# deployer EOA (lowercased), which we derived above from the PK.
DEPLOYER_LC="$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')"
SOURCE_BUNDLE=$(ls "$PREPARE_DIR"/*"$DEPLOYER_LC".safe.json 2>/dev/null | tail -1)
if [[ -z "$SOURCE_BUNDLE" ]]; then
  echo "No deployer bundle for $DEPLOYER under $PREPARE_DIR — run regen-and-verify-stage.sh first" >&2
  exit 1
fi
echo "Source deployer bundle: $SOURCE_BUNDLE"

# Filter the bundle to CREATE2-factory calls only.
FILTERED="$OUT/deployer-bundle-create2-only.safe.json"
python3 <<PY
import json
src = "$SOURCE_BUNDLE"
dst = "$FILTERED"
d = json.load(open(src))
factory = "0x4e59b44847b379578588920cA78FbF26c0B4956C".lower()
all_txs = d.get("transactions", [])
create2_txs = [tx for tx in all_txs if tx["to"].lower() == factory]
out = {**d, "transactions": create2_txs}
json.dump(out, open(dst, "w"), indent=2)
print(f"Filtered bundle: {len(all_txs)} → {len(create2_txs)} CREATE2 deploys")
PY

EXECUTED_OUT="$OUT/sepolia-deployer-deploys.json"
echo "Executing $FILTERED against $L1_RPC_URL …"
"$PROTOCOL_OPS" dev execute-safe \
  --safe-file "$FILTERED" \
  --l1-rpc-url "$L1_RPC_URL" \
  --private-key "$DEPLOYER_PK" \
  --out "$EXECUTED_OUT"

echo "=== Done ==="
echo "Executed log: $EXECUTED_OUT"
