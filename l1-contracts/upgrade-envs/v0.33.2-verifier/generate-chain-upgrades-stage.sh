#!/usr/bin/env bash
# Regenerate the per-chain v0.33.2 bundles for the ZKsync OS stage ecosystem, the same way the v33
# testnet ones were made (see ../v0.33.0-atomic-interop/output/testnet/chain-upgrades/README.md):
#   1. an anvil fork of Sepolia with the ecosystem upgrade applied (apply-ecosystem-upgrade-to-fork.sh),
#      so the CTM has the v0.33.0 cut registered
#   2. per chain in stage.toml's `chain_ids`:
#        protocol_ops chain set-upgrade-timestamp --upgrade-timestamp 1  -> 01_chain.set-upgrade-timestamp_*.safe.json
#        protocol_ops chain upgrade                                     -> 02_chain.upgrade_*.safe.json
#      into output/stage/chain-upgrades/<id>/, and checks the cut bundle equals the script's
#      `[chain_upgrades.<id>].chain_admin_calldata`
#   3. protocol_ops ecosystem manifest-to-simulator -> output/stage/simulator/<date>-v0.33.2-verifier-stage-2-chain-<id>.json
#
# `chain upgrade` replays the cut on the fork, and the cut reverts with `NotAllBatchesExecuted()` while
# the chain has committed-but-unexecuted batches. For a chain in that state the generation fork (never a
# real network, never the rehearsal) gets its batch counters advanced to what a drained executor
# produces, exactly as the v33 testnet README describes. The emitted calldata does not depend on it.
#
# DA is left as it is on every chain. The chains in stage.toml's `keep_unrecommended_da_chain_ids`
# run a DA setup protocol-ops flags as not recommended; they get `--acknowledge-unrecommended-noda`.
#
# Needs: foundry (forge/cast/anvil) with foundry-zksync v0.1.5 first on PATH, python3, a release
# build of protocol-ops, and an up-to-date output/stage/ecosystem.toml (generate-stage.sh).
# Usage: L1_FORK_URL=<sepolia rpc> [CHAIN_IDS="<id> ..."] ./generate-chain-upgrades-stage.sh [scenario-date, default: today]
# (PORT defaults to 8735). Only the anvil it starts is stopped (by PID).
set -euo pipefail

: "${L1_FORK_URL:?set L1_FORK_URL to a Sepolia RPC}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT=$HERE/output/stage/ecosystem.toml
CHAINS_DIR=$HERE/output/stage/chain-upgrades
SIM_DIR=$HERE/output/stage/simulator
DATE=${1:-$(date -u +%Y-%m-%d)}
PROTOCOL_OPS=${PROTOCOL_OPS:-$REPO/protocol-ops/target/release/protocol_ops}
PORT=${PORT:-8735}
RPC=http://127.0.0.1:$PORT
S=$(mktemp -d)

toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }

anvil --fork-url "$L1_FORK_URL" --port "$PORT" --auto-impersonate --silent > "$S/anvil.log" 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
echo "fork block: $(cast block-number --rpc-url "$RPC")"
RPC=$RPC ECOSYSTEM_TOML=$OUT "$HERE/apply-ecosystem-upgrade-to-fork.sh"

BH=$(cast call "$(toml_get state_transition.chain_type_manager_proxy)" 'BRIDGE_HUB()(address)' --rpc-url "$RPC")
# CHAIN_IDS (space-separated) regenerates a subset; the default is every chain in stage.toml.
CHAIN_IDS=${CHAIN_IDS:-$(python3 -c "import tomllib; print(' '.join(str(c) for c in tomllib.load(open('$HERE/stage.toml','rb'))['chain_ids']))")}
for ID in $CHAIN_IDS; do
  DIR=$CHAINS_DIR/$ID
  rm -rf "$DIR" "$SIM_DIR/$DATE-v0.33.2-verifier-stage-2-chain-$ID.json"
  CHAIN=$(toml_get chain_upgrades.$ID.chain)
  "$PROTOCOL_OPS" chain set-upgrade-timestamp --bridgehub "$BH" --chain-id "$ID" --upgrade-timestamp 1 \
    --l1-rpc-url "$RPC" --out "$DIR" > "$S/ts_$ID.log" 2>&1 || { cat "$S/ts_$ID.log"; exit 1; }

  COMMITTED=$(cast storage "$CHAIN" 13 --rpc-url "$RPC") # totalBatchesCommitted
  if [ "$COMMITTED" != "$(cast storage "$CHAIN" 11 --rpc-url "$RPC")" ]; then
    echo "chain $ID: batches in flight, advancing the generation fork's executed/verified counters"
    cast rpc anvil_setStorageAt "$CHAIN" 0xb "$COMMITTED" --rpc-url "$RPC" >/dev/null # totalBatchesExecuted
    cast rpc anvil_setStorageAt "$CHAIN" 0xc "$COMMITTED" --rpc-url "$RPC" >/dev/null # totalBatchesVerified
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  fi
  DA_ARGS=()
  if python3 -c "import tomllib,sys; sys.exit(0 if $ID in tomllib.load(open('$HERE/stage.toml','rb'))['keep_unrecommended_da_chain_ids'] else 1)"; then
    DA_ARGS=(--acknowledge-unrecommended-noda)
  fi
  "$PROTOCOL_OPS" chain upgrade --bridgehub "$BH" --chain-id "$ID" "${DA_ARGS[@]}" \
    --l1-rpc-url "$RPC" --out "$DIR" > "$S/up_$ID.log" 2>&1 || { cat "$S/up_$ID.log"; exit 1; }
  grep -o 'DA after the upgrade: .*' "$S/up_$ID.log" | sed "s/^/chain $ID: /"

  python3 - "$DIR" "$(toml_get chain_upgrades.$ID.chain_admin)" "$(toml_get chain_upgrades.$ID.chain_admin_calldata)" <<'PY'
import glob, json, sys
d, admin, expected = sys.argv[1:]
txs = json.load(open(glob.glob(f"{d}/02_chain.upgrade_*.safe.json")[0]))["transactions"]
assert len(txs) == 1, txs
assert txs[0]["to"].lower() == admin.lower(), txs[0]["to"]
assert txs[0]["data"].lower() == expected.lower(), "cut bundle differs from [chain_upgrades].chain_admin_calldata"
PY
  echo "chain $ID: bundles written, cut = [chain_upgrades.$ID].chain_admin_calldata"

  "$PROTOCOL_OPS" ecosystem manifest-to-simulator --manifest "$DIR/manifest.json" \
    --network sepolia --tag "chain_upgrade_$ID" \
    --descriptions "$HERE/sim-descriptions.toml" \
    --emulate-all-batches-executed-for "$CHAIN" \
    --out "$SIM_DIR/$DATE-v0.33.2-verifier-stage-2-chain-$ID.json" > "$S/sim_$ID.log" 2>&1 || { cat "$S/sim_$ID.log"; exit 1; }
done
echo "per-chain bundles: $CHAINS_DIR"
