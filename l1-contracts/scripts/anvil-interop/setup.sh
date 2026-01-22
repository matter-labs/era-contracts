#!/bin/bash

set -e

echo "🔧 Setting up Anvil Interop Environment"
echo ""

# Check if we're in the correct directory
if [ ! -f "package.json" ]; then
    echo "❌ Error: Must run from anvil-interop directory"
    exit 1
fi

# Navigate to contracts root
cd ../../..

echo "📦 Building contract artifacts..."
echo ""

echo "  Building da-contracts..."
yarn da build:foundry

echo "  Building l1-contracts..."
yarn l1 build:foundry

echo "  Building system-contracts..."
yarn sc build:foundry

echo "  Building l2-contracts..."
yarn l2 build:foundry

echo ""
echo "✅ All artifacts built successfully"
echo ""

# Return to anvil-interop directory
cd l1-contracts/scripts/anvil-interop

echo "📦 Installing dependencies..."
yarn install

echo ""
echo "✅ Setup complete!"
echo ""
echo "You can now start the environment with:"
echo "  yarn start"
echo ""
