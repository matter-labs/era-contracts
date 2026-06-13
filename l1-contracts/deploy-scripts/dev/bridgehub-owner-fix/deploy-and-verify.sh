#!/usr/bin/env bash
#
# Deploy and verify the temporary `BridgehubOwnerForceUpdate` implementation used to repair
# the misconfigured Bridgehub proxy (its `_owner` slot is address(0)).
#
# The script is idempotent / restartable: it records the deployed address in
# `deploy-scripts/dev/bridgehub-owner-fix/deployment.env` and skips deployment if it already
# exists, so you can re-run it to (re)verify without redeploying.
#
# Requirements:
#   - foundry (forge, cast)
#   - env vars:
#       RPC_URL             L1 RPC (e.g. Sepolia)
#       PRIVATE_KEY         deployer private key (needs a little ETH for gas)
#       ETHERSCAN_API_KEY   Etherscan (v2) API key, required for verification
#   - optional env vars (defaults shown):
#       L1_CHAIN_ID         11155111
#       IMPL_OWNER          0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D  (constructor _owner; irrelevant to the fix)
#       MAX_NUMBER_OF_ZK_CHAINS  100
#       CHAIN               sepolia   (forge --chain value for verification)
#
# Usage:
#   RPC_URL=... PRIVATE_KEY=... ETHERSCAN_API_KEY=... ./deploy-and-verify.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L1_DIR="$(cd "$HERE/../../.." && pwd)"   # l1-contracts root
STATE_FILE="$HERE/deployment.env"

: "${RPC_URL:?set RPC_URL}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
L1_CHAIN_ID="${L1_CHAIN_ID:-11155111}"
IMPL_OWNER="${IMPL_OWNER:-0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D}"
MAX_NUMBER_OF_ZK_CHAINS="${MAX_NUMBER_OF_ZK_CHAINS:-100}"
CHAIN="${CHAIN:-sepolia}"
CONTRACT="contracts/dev-contracts/BridgehubOwnerForceUpdate.sol:BridgehubOwnerForceUpdate"

cd "$L1_DIR"

# ---------------------------------------------------------------------------
# Step 1: deploy (skipped if deployment.env already records an address)
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]] && grep -q "TEMP_IMPL=0x" "$STATE_FILE"; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo "Step 1: already deployed at $TEMP_IMPL (from $STATE_FILE) — skipping deployment."
else
  echo "Step 1: deploying $CONTRACT ..."
  OUT="$(forge create "$CONTRACT" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
    --constructor-args "$L1_CHAIN_ID" "$IMPL_OWNER" "$MAX_NUMBER_OF_ZK_CHAINS")"
  echo "$OUT"
  TEMP_IMPL="$(echo "$OUT" | grep -i "Deployed to:" | awk '{print $3}')"
  if [[ -z "${TEMP_IMPL:-}" ]]; then echo "ERROR: could not parse deployed address"; exit 1; fi
  {
    echo "TEMP_IMPL=$TEMP_IMPL"
    echo "L1_CHAIN_ID=$L1_CHAIN_ID"
    echo "IMPL_OWNER=$IMPL_OWNER"
    echo "MAX_NUMBER_OF_ZK_CHAINS=$MAX_NUMBER_OF_ZK_CHAINS"
  } > "$STATE_FILE"
  echo "Recorded deployment to $STATE_FILE"
fi

# ---------------------------------------------------------------------------
# Step 2: verify on Etherscan
# ---------------------------------------------------------------------------
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY to verify}"
echo "Step 2: verifying $TEMP_IMPL on Etherscan ($CHAIN) ..."
CTOR_ARGS="$(cast abi-encode 'constructor(uint256,address,uint256)' "$L1_CHAIN_ID" "$IMPL_OWNER" "$MAX_NUMBER_OF_ZK_CHAINS")"
forge verify-contract "$TEMP_IMPL" "$CONTRACT" \
  --chain "$CHAIN" \
  --constructor-args "$CTOR_ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch

echo "Done. Temporary implementation deployed & verified at: $TEMP_IMPL"
echo "Next: run GenerateBridgehubOwnerFixCalldata with TEMP_IMPL=$TEMP_IMPL to produce the governance calldata."
