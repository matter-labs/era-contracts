#!/bin/bash

# Script to run all setup steps in sequence
# This is more reliable than using yarn step:all because it ensures proper sequencing

set -e

echo "=========================================="
echo "  ZKSync Anvil Interop - Full Setup"
echo "=========================================="
echo ""

# Step 1: Start chains (in background)
echo "📍 Step 1: Starting Anvil chains..."
yarn step1
if [ $? -ne 0 ]; then
    echo "❌ Step 1 failed"
    exit 1
fi
echo "✅ Step 1 complete"
echo ""

# Give chains a moment to stabilize
sleep 2

# Step 2: Deploy L1 contracts
echo "📍 Step 2: Deploying L1 contracts..."
yarn step2
if [ $? -ne 0 ]; then
    echo "❌ Step 2 failed"
    yarn cleanup
    exit 1
fi
echo "✅ Step 2 complete"
echo ""

# Step 3: Register chains
echo "📍 Step 3: Registering L2 chains..."
yarn step3
if [ $? -ne 0 ]; then
    echo "❌ Step 3 failed"
    yarn cleanup
    exit 1
fi
echo "✅ Step 3 complete"
echo ""

# Step 4: Initialize L2 with genesis upgrade
echo "📍 Step 4: Initializing L2 (L2GenesisUpgrade with isZKsyncOS=true)..."
yarn step4
if [ $? -ne 0 ]; then
    echo "❌ Step 4 failed"
    yarn cleanup
    exit 1
fi
echo "✅ Step 4 complete"
echo ""

# Step 5: Setup gateway
echo "📍 Step 5: Setting up gateway..."
yarn step5
if [ $? -ne 0 ]; then
    echo "❌ Step 5 failed"
    yarn cleanup
    exit 1
fi
echo "✅ Step 5 complete"
echo ""

# Step 6: Start batch settler and relayers (in background)
echo "📍 Step 6: Starting batch settler and relayers..."
yarn step6 > /tmp/step6-output.log 2>&1 &
STEP6_PID=$!
echo "   Batch settler started (PID: $STEP6_PID)"
echo "   Logs: /tmp/step6-output.log"
sleep 3  # Give time for daemons to initialize
echo "✅ Step 6 complete"
echo ""

echo "=========================================="
echo "  ✅ All steps completed successfully!"
echo "=========================================="
echo ""
echo "🎉 Full interop environment is running!"
echo ""
echo "You can now:"
echo "  - Test L2→L2 messaging: yarn send:l2-to-l2"
echo "  - Send token transfers: yarn send:token"
echo "  - Run interop tests: yarn test:interop"
echo ""
echo "Monitoring:"
echo "  - Batch settler logs: tail -f /tmp/step6-output.log"
echo "  - Settler PID: $STEP6_PID"
echo ""
echo "To clean up:"
echo "  yarn cleanup  (stops all Anvil chains and settler)"
echo ""
