#!/bin/bash

TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
VAULT="0x0000000000000000000000000000000000010004"
CHAIN_ID=10

echo "=== Manual Storage Test ==="
echo ""

# Calculate slot for assetId[TOKEN] (slot 51)
SLOT_51=$(cast index address $TOKEN 51)
echo "1. Setting assetId[$TOKEN] = $ASSET_ID"
echo "   Slot: $SLOT_51"
cast rpc anvil_setStorageAt $VAULT $SLOT_51 $ASSET_ID -r http://127.0.0.1:4050
echo ""

# Verify immediately
echo "2. Reading back..."
VALUE=$(cast storage $VAULT $SLOT_51 -r http://127.0.0.1:4050)
echo "   Got: $VALUE"
echo ""

# Call the contract function
echo "3. Calling assetId($TOKEN)..."
RESULT=$(cast call $VAULT "assetId(address)(bytes32)" $TOKEN -r http://127.0.0.1:4050)
echo "   Result: $RESULT"
echo ""

if [ "$RESULT" == "$ASSET_ID" ]; then
    echo "✅ SUCCESS!"
else
    echo "❌ FAILED - storage read doesn't match contract call"
fi
