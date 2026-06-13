#!/usr/bin/env bash
#
# Deploy and verify the temporary `ChainAssetHandlerOwnerForceUpdate` implementation used to repair
# the misconfigured L1ChainAssetHandler proxy (its `_owner` slot is address(0)).
#
# The script is idempotent / restartable: it records the deployed address in
# `deployment.env` (next to this script) and skips deployment if it already exists, so you can
# re-run it to (re)verify without redeploying.
#
# Requirements:
#   - foundry (forge, cast)
#   - env vars:
#       RPC_URL             L1 RPC (e.g. Sepolia)
#       PRIVATE_KEY         deployer private key (needs a little ETH for gas)
#       ETHERSCAN_API_KEY   Etherscan (v2) API key, required for verification
#   - optional env vars (defaults match the broken ZKsync Sepolia deployment's immutables):
#       L1_CHAIN_ID         11155111
#       IMPL_OWNER          0x5555555590930f501c88B73Ea43B3EEb5A71643c
#       BRIDGEHUB           0xc4fd2580c3487bba18d63f50301020132342fdbd
#       ASSET_ROUTER        0xb5d9c3f41e434b91295bd7962db5c873cecce2be
#       MESSAGE_ROOT        0xe7047cd9979d053ceb6db637bc0383b87a3c7f58
#       CHAIN               sepolia
#
# Note: the constructor args are immutables that are irrelevant to `forceSetOwner`; they default to
# the exact values used by the deployed original implementation so the temporary implementation is
# byte-for-byte identical except for the added `forceSetOwner` function.
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
IMPL_OWNER="${IMPL_OWNER:-0x5555555590930f501c88B73Ea43B3EEb5A71643c}"
BRIDGEHUB="${BRIDGEHUB:-0xc4fd2580c3487bba18d63f50301020132342fdbd}"
ASSET_ROUTER="${ASSET_ROUTER:-0xb5d9c3f41e434b91295bd7962db5c873cecce2be}"
MESSAGE_ROOT="${MESSAGE_ROOT:-0xe7047cd9979d053ceb6db637bc0383b87a3c7f58}"
CHAIN="${CHAIN:-sepolia}"
CONTRACT="contracts/dev-contracts/ChainAssetHandlerOwnerForceUpdate.sol:ChainAssetHandlerOwnerForceUpdate"

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
    --constructor-args "$L1_CHAIN_ID" "$IMPL_OWNER" "$BRIDGEHUB" "$ASSET_ROUTER" "$MESSAGE_ROOT")"
  echo "$OUT"
  TEMP_IMPL="$(echo "$OUT" | grep -i "Deployed to:" | awk '{print $3}')"
  if [[ -z "${TEMP_IMPL:-}" ]]; then echo "ERROR: could not parse deployed address"; exit 1; fi
  {
    echo "TEMP_IMPL=$TEMP_IMPL"
    echo "L1_CHAIN_ID=$L1_CHAIN_ID"
    echo "IMPL_OWNER=$IMPL_OWNER"
    echo "BRIDGEHUB=$BRIDGEHUB"
    echo "ASSET_ROUTER=$ASSET_ROUTER"
    echo "MESSAGE_ROOT=$MESSAGE_ROOT"
  } > "$STATE_FILE"
  echo "Recorded deployment to $STATE_FILE"
fi

# ---------------------------------------------------------------------------
# Step 2: verify on Etherscan
# ---------------------------------------------------------------------------
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY to verify}"
echo "Step 2: verifying $TEMP_IMPL on Etherscan ($CHAIN) ..."
CTOR_ARGS="$(cast abi-encode 'constructor(uint256,address,address,address,address)' \
  "$L1_CHAIN_ID" "$IMPL_OWNER" "$BRIDGEHUB" "$ASSET_ROUTER" "$MESSAGE_ROOT")"
forge verify-contract "$TEMP_IMPL" "$CONTRACT" \
  --chain "$CHAIN" \
  --constructor-args "$CTOR_ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch

echo "Done. Temporary implementation deployed & verified at: $TEMP_IMPL"
echo "Next: run GenerateChainAssetHandlerOwnerFixCalldata with TEMP_IMPL=$TEMP_IMPL to produce the governance calldata."
