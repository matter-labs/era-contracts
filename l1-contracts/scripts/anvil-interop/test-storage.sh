#!/bin/bash

# Test token address
TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
# Asset ID for this token  
ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
# L2NativeTokenVault address
VAULT="0x0000000000000000000000000000000000010004"
# Chain ID
CHAIN_ID=10

echo "Token: $TOKEN"
echo "Asset ID: $ASSET_ID"
echo ""

# Try different storage slots for the assetId mapping
# Based on inheritance: Ownable2Step (slots 0-1), Pausable (slot 2), then NativeTokenVaultBase
for BASE_SLOT in 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65; do
    # Calculate slot for assetId[TOKEN]
    SLOT=$(cast index address $TOKEN $BASE_SLOT)
    echo "Trying slot $BASE_SLOT -> $SLOT"
    
    # Set the storage
    cast rpc anvil_setStorageAt $VAULT $SLOT $ASSET_ID -r http://127.0.0.1:4050 > /dev/null 2>&1
    
    # Read back
    VALUE=$(cast storage $VAULT $SLOT -r http://127.0.0.1:4050)
    if [ "$VALUE" == "$ASSET_ID" ]; then
        echo "✅ SUCCESS! assetId mapping is at slot $BASE_SLOT"
        echo "   Storage slot: $SLOT"
        break
    fi
done
