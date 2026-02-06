#!/bin/bash

VAULT="0x0000000000000000000000000000000000010004"
ASSET_ROUTER="0x0000000000000000000000000000000000010003"
ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
CALLER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
AMOUNT="1000000000000000000"

DATA=$(cast abi-encode "f(uint256,address,address)" $AMOUNT $CALLER $TOKEN)

echo "Brute-forcing storage slot for assetId mapping..."
echo ""

cast rpc anvil_impersonateAccount $ASSET_ROUTER -r http://127.0.0.1:4050 > /dev/null 2>&1

for BASE_SLOT in {45..70}; do
    # Calculate slot for assetId[TOKEN]
    SLOT=$(cast index address $TOKEN $BASE_SLOT)
    
    # Set the storage
    cast rpc anvil_setStorageAt $VAULT $SLOT $ASSET_ID -r http://127.0.0.1:4050 > /dev/null 2>&1
    
    # Try bridgeBurn
    RESULT=$(cast call $VAULT "bridgeBurn(uint256,uint256,bytes32,address,bytes)(bytes)" \
      11 0 $ASSET_ID $CALLER $DATA \
      --from $ASSET_ROUTER \
      -r http://127.0.0.1:4050 2>&1)
    
    # Check if it succeeded (no error)
    if [[ ! "$RESULT" =~ "Error" ]] && [[ ! "$RESULT" =~ "revert" ]]; then
        echo "✅ SUCCESS! assetId mapping is at slot $BASE_SLOT"
        echo "   Result: $RESULT"
        break
    fi
    
    # Clear the slot
    cast rpc anvil_setStorageAt $VAULT $SLOT 0x0000000000000000000000000000000000000000000000000000000000000000 -r http://127.0.0.1:4050 > /dev/null 2>&1
    
    printf "."
done

echo ""
cast rpc anvil_stopImpersonatingAccount $ASSET_ROUTER -r http://127.0.0.1:4050 > /dev/null 2>&1
