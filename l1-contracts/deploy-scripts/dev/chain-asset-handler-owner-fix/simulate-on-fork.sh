#!/usr/bin/env bash
#
# Simulate the L1ChainAssetHandler owner fix on an anvil fork and verify the intended outcome:
#   - after executing the governance calldata, the proxy's implementation equals the ORIGINAL impl
#   - the proxy's `owner()` returns the intended NEW_OWNER
#
# It spins up an anvil fork, impersonates the Governance owner EOA (anvil "unlocked" account),
# sends the two transactions from calldata.json (scheduleTransparent + execute), and asserts the
# resulting on-chain state. Exits non-zero if any assertion fails.
#
# Requirements: foundry (anvil, cast), python3, jq-free (uses python for JSON).
#
# Env vars:
#   RPC_URL          L1 RPC to fork (required; e.g. a Sepolia RPC)
#   CALLDATA_JSON    path to the calldata array (default: ./calldata.json next to this script)
#   PORT             anvil port (default 8546)
#   PROXY            L1ChainAssetHandler proxy (default 0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C)
#   EXPECTED_IMPL    impl expected after the fix (default original 0xC32F...9354F)
#   NEW_OWNER        owner expected after the fix (default 0x803e...471D)
#   GOVERNANCE       governance contract (default 0xcf96...2b58)
#   GOVERNANCE_OWNER EOA that signs / is impersonated (default 0x5555...643c)
#
# Usage:
#   RPC_URL=$SEPOLIA_RPC ./simulate-on-fork.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RPC_URL:?set RPC_URL to the L1 RPC you want to fork}"
CALLDATA_JSON="${CALLDATA_JSON:-$HERE/calldata.json}"
PORT="${PORT:-8546}"
L="http://127.0.0.1:${PORT}"
PROXY="${PROXY:-0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C}"
EXPECTED_IMPL="${EXPECTED_IMPL:-0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F}"
NEW_OWNER="${NEW_OWNER:-0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D}"
GOVERNANCE="${GOVERNANCE:-0xcf96aAb01347BA96050F39Ff6dcbC6138b462b58}"
GOVERNANCE_OWNER="${GOVERNANCE_OWNER:-0x5555555590930f501c88B73Ea43B3EEb5A71643c}"
# EIP-1967 implementation slot.
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

[[ -f "$CALLDATA_JSON" ]] || { echo "ERROR: calldata file not found: $CALLDATA_JSON"; exit 1; }

ANVIL_PID=""
cleanup() { [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "Starting anvil fork of $RPC_URL on port $PORT ..."
anvil --fork-url "$RPC_URL" --port "$PORT" --silent &
ANVIL_PID=$!

# wait for anvil to be ready
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$L" >/dev/null 2>&1; then break; fi
  sleep 1
done
cast block-number --rpc-url "$L" >/dev/null 2>&1 || { echo "ERROR: anvil did not start"; exit 1; }

# read the two tx datas (entry 0 = scheduleTransparent, entry 1 = execute)
SCHED_DATA="$(python3 -c "import json,sys;print(json.load(open('$CALLDATA_JSON'))[0]['data'])")"
EXEC_DATA="$(python3 -c "import json,sys;print(json.load(open('$CALLDATA_JSON'))[1]['data'])")"

addr_eq() { [[ "$(echo "$1" | tr 'A-F' 'a-f')" == "$(echo "$2" | tr 'A-F' 'a-f')" ]]; }

OWNER_BEFORE="$(cast call "$PROXY" 'owner()(address)' --rpc-url "$L" 2>/dev/null)"
echo "owner() before: $OWNER_BEFORE"

# fund + impersonate the governance owner (unlocked account)
cast rpc anvil_setBalance "$GOVERNANCE_OWNER" 0xde0b6b3a7640000 --rpc-url "$L" >/dev/null 2>&1
cast rpc anvil_impersonateAccount "$GOVERNANCE_OWNER" --rpc-url "$L" >/dev/null 2>&1

echo "Sending scheduleTransparent(operation, 0) ..."
cast send "$GOVERNANCE" "$SCHED_DATA" --from "$GOVERNANCE_OWNER" --unlocked --rpc-url "$L" >/dev/null 2>&1
echo "Sending execute(operation) ..."
cast send "$GOVERNANCE" "$EXEC_DATA" --from "$GOVERNANCE_OWNER" --unlocked --rpc-url "$L" >/dev/null 2>&1

# read resulting state
IMPL_RAW="$(cast storage "$PROXY" "$IMPL_SLOT" --rpc-url "$L" 2>/dev/null)"
IMPL_AFTER="0x${IMPL_RAW: -40}"
OWNER_AFTER="$(cast call "$PROXY" 'owner()(address)' --rpc-url "$L" 2>/dev/null)"

echo
echo "owner() after:        $OWNER_AFTER  (expected $NEW_OWNER)"
echo "implementation after: $IMPL_AFTER  (expected $EXPECTED_IMPL)"

FAIL=0
if addr_eq "$OWNER_AFTER" "$NEW_OWNER"; then
  echo "PASS: owner() is the intended new owner"
else
  echo "FAIL: owner() is not the intended new owner"; FAIL=1
fi
if addr_eq "$IMPL_AFTER" "$EXPECTED_IMPL"; then
  echo "PASS: implementation restored to the original impl"
else
  echo "FAIL: implementation is not the original impl"; FAIL=1
fi

# sanity: the restored implementation is still callable (e.g. migrationPaused())
if cast call "$PROXY" 'migrationPaused()(bool)' --rpc-url "$L" >/dev/null 2>&1; then
  echo "PASS: proxy is functional on the restored implementation (migrationPaused() callable)"
else
  echo "FAIL: proxy not functional after restore"; FAIL=1
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL CHECKS PASSED ✅"
else
  echo "SOME CHECKS FAILED ❌"
fi
exit "$FAIL"
