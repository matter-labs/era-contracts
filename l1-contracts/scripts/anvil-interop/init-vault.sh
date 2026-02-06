#!/bin/bash

VAULT="0x0000000000000000000000000000000000010004"
ASSET_ROUTER="0x0000000000000000000000000000000000010003"

echo "Initializing L2NativeTokenVault..."
echo "  Vault: $VAULT"
echo "  AssetRouter: $ASSET_ROUTER"
echo ""

# Find the storage slot for ASSET_ROUTER or assetRouter
# Try common slots for the assetRouter address
for SLOT in 0 1 2 3 4 5 6 7 8 9 10 48 49 50; do
    # Encode the address
    PADDED=$(cast abi-encode "f(address)" $ASSET_ROUTER)
    
    # Set storage
    cast rpc anvil_setStorageAt $VAULT $(printf "0x%064x" $SLOT) $PADDED -r http://127.0.0.1:4050 > /dev/null 2>&1
    
    # Check if it worked
    RESULT=$(cast call $VAULT "assetRouter()(address)" -r http://127.0.0.1:4050 2>/dev/null)
    if [ "$RESULT" == "$ASSET_ROUTER" ]; then
        echo "✅ Found assetRouter at slot $SLOT"
        exit 0
    fi
done

echo "❌ Could not find assetRouter storage slot"
