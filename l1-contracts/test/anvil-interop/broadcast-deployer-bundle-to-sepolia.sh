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

# Locate every deployer bundle in $PREPARE_DIR. Upstream's `upgrade-prepare-all`
# can split the deployer's txs across multiple bundles (e.g. one per orchestration
# step), so we need to broadcast CREATE2 deploys from ALL of them — not just the
# last-sorted one. The filename suffix is the deployer EOA (lowercased), which we
# derived above from the PK.
DEPLOYER_LC="$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')"
shopt -s nullglob
SOURCE_BUNDLES=("$PREPARE_DIR"/*"$DEPLOYER_LC".safe.json)
shopt -u nullglob
if [[ ${#SOURCE_BUNDLES[@]} -eq 0 ]]; then
  echo "No deployer bundle for $DEPLOYER under $PREPARE_DIR — run regen-and-verify-stage.sh first" >&2
  exit 1
fi
echo "Source deployer bundles (${#SOURCE_BUNDLES[@]}):"
for b in "${SOURCE_BUNDLES[@]}"; do echo "  $b"; done

# Merge all bundles, keep CREATE2-factory calls only, then drop any CREATE2
# whose computed deploy address already has code on $L1_RPC_URL. The script
# is idempotent: re-running after a partial broadcast or after a prior
# upgrade-ceremony broadcast only sends the deploys that are net-new for
# this regen. Skipping non-CREATE2 txs is intentional too — token approves
# and GW priority requests in the deployer bundles need ZK base-token the
# deployer EOA doesn't hold on $L1_RPC_URL, and the simulator only needs
# `eth_getCode` to find bytecode at CREATE2-derived targets.
FILTERED="$OUT/deployer-bundle-create2-only.safe.json"
python3 - "$FILTERED" "$L1_RPC_URL" "${SOURCE_BUNDLES[@]}" <<'PY'
import json, subprocess, sys, re
dst = sys.argv[1]
rpc = sys.argv[2]
srcs = sys.argv[3:]
factory = "0x4e59b44847b379578588920cA78FbF26c0B4956C".lower()

# 1) Merge + filter to CREATE2-factory calls
merged = None
total_in = 0
create2 = []
for src in srcs:
    d = json.load(open(src))
    if merged is None:
        merged = {k: v for k, v in d.items() if k != "transactions"}
    txs = d.get("transactions", [])
    total_in += len(txs)
    create2.extend(tx for tx in txs if tx["to"].lower() == factory)

# 2) Drop CREATE2 calls whose target address already has code on chain.
# data layout: 0x | salt(32) | initcode. CREATE2 addr = keccak(0xff || factory
# || salt || keccak(initcode))[12:]. Use `cast keccak` + `cast create2` so we
# don't pull a python keccak/keccak deps in.
def addr_for(tx_data: str) -> str:
    salt = "0x" + tx_data[2:66]
    init = "0x" + tx_data[66:]
    init_hash = subprocess.check_output(
        ["cast", "keccak", init], stderr=subprocess.DEVNULL
    ).decode().strip()
    out = subprocess.check_output(
        ["cast", "create2", "--salt", salt, "--init-code-hash", init_hash,
         "--deployer", "0x4e59b44847b379578588920cA78FbF26c0B4956C"],
        stderr=subprocess.DEVNULL,
    ).decode()
    m = re.search(r"(0x[0-9a-fA-F]{40})", out)
    return m.group(1) if m else None

def has_code(addr: str) -> bool:
    out = subprocess.check_output(
        ["cast", "code", addr, "--rpc-url", rpc],
        stderr=subprocess.DEVNULL,
    ).decode().strip()
    return len(out) > 2  # "0x" alone = no code

to_send = []
skipped = []
for tx in create2:
    addr = addr_for(tx["data"])
    if addr is None:
        # Unparsable — keep, let the broadcaster fail loudly
        to_send.append(tx)
        continue
    if has_code(addr):
        skipped.append(addr)
    else:
        to_send.append(tx)

merged["transactions"] = to_send
json.dump(merged, open(dst, "w"), indent=2)
print(f"Merged: {total_in} txs across {len(srcs)} bundle(s) → "
      f"{len(create2)} CREATE2 → {len(to_send)} new, {len(skipped)} already deployed")
PY
if [[ "$(jq '.transactions | length' "$FILTERED")" == "0" ]]; then
  echo "All CREATE2 targets already deployed on $L1_RPC_URL — nothing to broadcast."
  exit 0
fi

EXECUTED_OUT="$OUT/sepolia-deployer-deploys.json"
echo "Executing $FILTERED against $L1_RPC_URL …"
"$PROTOCOL_OPS" dev execute-safe \
  --safe-file "$FILTERED" \
  --l1-rpc-url "$L1_RPC_URL" \
  --private-key "$DEPLOYER_PK" \
  --out "$EXECUTED_OUT"

echo "=== Done ==="
echo "Executed log: $EXECUTED_OUT"
