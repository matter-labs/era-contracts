#!/bin/bash

TOKEN="0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
ASSET_ID="0x9622678ae46c4cd5e0b4eab4916da92838ea3aa251660757a680c0534c4e7f5a"
VAULT="0x0000000000000000000000000000000000010004"
SLOT=$(cast index address $TOKEN 51)

echo "=== Storage Persistence Test ==="
echo ""
echo "1. Initial state:"
VALUE=$(cast storage $VAULT $SLOT -r http://127.0.0.1:4050)
echo "   Storage: $VALUE"
echo ""

echo "2. Setting storage to $ASSET_ID"
cast rpc anvil_setStorageAt $VAULT $SLOT $ASSET_ID -r http://127.0.0.1:4050 > /dev/null
echo ""

echo "3. Immediately after set:"
VALUE=$(cast storage $VAULT $SLOT -r http://127.0.0.1:4050)
echo "   Storage: $VALUE"
echo ""

echo "4. Mining a block..."
cast rpc anvil_mine 1 -r http://127.0.0.1:4050 > /dev/null
echo ""

echo "5. After mining:"
VALUE=$(cast storage $VAULT $SLOT -r http://127.0.0.1:4050)
echo "   Storage: $VALUE"
echo ""

echo "6. Sending a simple transaction..."
cast send 0x1234567890123456789012345678901234567890 --value 0 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -r http://127.0.0.1:4050 > /dev/null 2>&1
echo ""

echo "7. After sending transaction:"
VALUE=$(cast storage $VAULT $SLOT -r http://127.0.0.1:4050)
echo "   Storage: $VALUE"
echo ""

if [ "$VALUE" == "$ASSET_ID" ]; then
    echo "✅ Storage persists!"
else
    echo "❌ Storage was cleared!"
fi
