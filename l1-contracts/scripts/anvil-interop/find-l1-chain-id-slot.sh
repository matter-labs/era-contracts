#!/bin/bash

VAULT="0x0000000000000000000000000000000000010004"

echo "Finding L1_CHAIN_ID storage slot..."

# L2NativeTokenVault inherits from Ownable2Step, Pausable, then has its own storage
# Try slots 0-10 to find L1_CHAIN_ID
for SLOT in {0..10}; do
    # Set slot to value 1
    PADDED_SLOT=$(printf "0x%064x" $SLOT)
    PADDED_VALUE=$(cast abi-encode "f(uint256)" 1)
    
    cast rpc anvil_setStorageAt $VAULT $PADDED_SLOT $PADDED_VALUE -r http://127.0.0.1:4050 > /dev/null 2>&1
    
    # Check if L1_CHAIN_ID() returns 1
    RESULT=$(cast call $VAULT "L1_CHAIN_ID()(uint256)" -r http://127.0.0.1:4050 2>/dev/null)
    
    if [ "$RESULT" == "1" ]; then
        echo "✅ L1_CHAIN_ID is at slot $SLOT"
        exit 0
    fi
done

echo "❌ L1_CHAIN_ID slot not found"
