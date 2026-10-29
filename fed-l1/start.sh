#!/usr/bin/env bash
# Restarts anvil from the state deploy.sh dumped (fed-l1/out/state.json), without redeploying.
# Same port/chain id/flags as deploy.sh. Addresses: fed-l1/out/addresses.json.
set -euo pipefail
FED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$FED_DIR/out"
PORT="${FED_L1_PORT:-8545}"
L1_CHAIN_ID="${FED_L1_CHAIN_ID:-31337}"
[[ -f "$OUT/state.json" ]] || { echo "no $OUT/state.json; run deploy.sh first" >&2; exit 1; }
if [[ -f "$OUT/anvil.pid" ]] && kill -0 "$(cat "$OUT/anvil.pid")" 2>/dev/null; then kill "$(cat "$OUT/anvil.pid")"; sleep 1; fi
# --load-state only (no --dump-state): every restart starts from the post-deploy snapshot.
nohup anvil --port "$PORT" --chain-id "$L1_CHAIN_ID" --accounts 10 --balance 10000 \
  --gas-limit 100000000 --block-base-fee-per-gas 0 --auto-impersonate \
  --load-state "$OUT/state.json" >"$OUT/anvil.log" 2>&1 &
echo $! >"$OUT/anvil.pid"
for _ in $(seq 1 50); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 0.2; done
BH=$(jq -r .contracts.bridgehub "$OUT/addresses.json")
echo "anvil pid $(cat "$OUT/anvil.pid") on :$PORT; chain 301 at $(cast call --rpc-url "http://127.0.0.1:$PORT" "$BH" "getZKChain(uint256)(address)" 301)"
