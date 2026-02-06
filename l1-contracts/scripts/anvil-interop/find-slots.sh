#!/bin/bash

ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
VAULT="0x0000000000000000000000000000000000010004"
CHAIN_ID=10

echo "Finding tokenAddress[assetId] mapping..."
for SLOT in 49 50 51 52 53 54; do
    CALC_SLOT=$(cast index bytes32 $ASSET_ID $SLOT)
    PADDED_TOKEN=$(cast abi-encode "f(address)" $TOKEN)
    cast rpc anvil_setStorageAt $VAULT $CALC_SLOT $PADDED_TOKEN -r http://127.0.0.1:4050 > /dev/null 2>&1
    VALUE=$(cast storage $VAULT $CALC_SLOT -r http://127.0.0.1:4050)
    if [ "$VALUE" == "$PADDED_TOKEN" ]; then
        echo "✅ tokenAddress mapping at slot $SLOT"
        break
    fi
done

echo ""
echo "Finding originChainId[assetId] mapping..."
for SLOT in 49 50 51 52 53 54; do
    CALC_SLOT=$(cast index bytes32 $ASSET_ID $SLOT)
    PADDED_CHAIN=$(cast abi-encode "f(uint256)" $CHAIN_ID)
    cast rpc anvil_setStorageAt $VAULT $CALC_SLOT $PADDED_CHAIN -r http://127.0.0.1:4050 > /dev/null 2>&1
    VALUE=$(cast storage $VAULT $CALC_SLOT -r http://127.0.0.1:4050)
    if [ "$VALUE" == "$PADDED_CHAIN" ]; then
        echo "✅ originChainId mapping at slot $SLOT"
        break
    fi
done
