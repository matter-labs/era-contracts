#!/bin/bash

# Create the calldata for bridgeBurn
VAULT="0x0000000000000000000000000000000000010004"
ASSET_ROUTER="0x0000000000000000000000000000000000010003"

# First, impersonate AssetRouter
cast rpc anvil_impersonateAccount $ASSET_ROUTER -r http://127.0.0.1:4050 > /dev/null

# Try to call bridgeBurn and trace it
# bridgeBurn(uint256 _chainId, uint256 _l2MsgValue, bytes32 _assetId, address _originalCaller, bytes calldata _data)
ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
CALLER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
AMOUNT="1000000000000000000"

# Encode the _data parameter (amount, receiver, tokenAddress)
DATA=$(cast abi-encode "f(uint256,address,address)" $AMOUNT $CALLER $TOKEN)

echo "Calling bridgeBurn with trace..."
echo "Asset ID: $ASSET_ID"
echo "Token: $TOKEN"
echo ""

cast call $VAULT "bridgeBurn(uint256,uint256,bytes32,address,bytes)(bytes)" \
  11 0 $ASSET_ID $CALLER $DATA \
  --from $ASSET_ROUTER \
  -r http://127.0.0.1:4050 \
  --trace 2>&1 | grep -A 2 -B 2 "SLOAD.*0xf32fe12ba43e1bee" | head -30

cast rpc anvil_stopImpersonatingAccount $ASSET_ROUTER -r http://127.0.0.1:4050 > /dev/null
