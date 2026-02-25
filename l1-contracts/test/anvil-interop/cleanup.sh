#!/bin/bash

# Cleanup script for Anvil interop testing environment
# This script stops all Anvil instances and cleans up deployment artifacts
# while preserving the original configuration files

set -e

echo "🧹 Cleaning up Anvil interop environment..."

# Known ports used by our Anvil instances
ANVIL_PORTS="9545 4050 4051 4052"

# Stop all Anvil instances - try graceful shutdown first using PIDs
echo "Stopping Anvil instances..."

# Try to use PID file for graceful shutdown
if [ -f "outputs/anvil-pids.json" ]; then
    echo "Found PID file, attempting graceful shutdown..."
    # Extract PIDs and kill them
    pids=$(cat outputs/anvil-pids.json | grep -o '"[0-9]*":' | grep -o '[0-9]*' || true)
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping Anvil process $pid..."
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    sleep 2
    # Remove PID file
    rm -f outputs/anvil-pids.json
fi

# Fallback: Kill processes on known Anvil ports only (not system-wide)
echo "Checking known Anvil ports..."
for PORT in $ANVIL_PORTS; do
    PID=$(lsof -ti :$PORT 2>/dev/null || true)
    if [ -n "$PID" ]; then
        echo "  Killing process on port $PORT (PID: $PID)..."
        kill -9 $PID 2>/dev/null || true
    fi
done
sleep 1

# Clean up step6 log file
rm -f /tmp/step6-output.log 2>/dev/null || true

# Verify ports are free
ALL_CLEAR=true
for PORT in $ANVIL_PORTS; do
    if lsof -ti :$PORT > /dev/null 2>&1; then
        echo "⚠️  Warning: Port $PORT is still in use"
        ALL_CLEAR=false
    fi
done

if [ "$ALL_CLEAR" = true ]; then
    echo "✅ All Anvil instances stopped"
else
    echo "⚠️  Some ports still in use, waiting..."
    sleep 2
fi

# Clean up output files
echo "Cleaning up output files..."
rm -rf outputs
mkdir -p outputs

# Reset permanent values to initial state
echo "Resetting permanent values..."
cat > config/permanent-values.toml << EOF
[permanent_contracts]
create2_factory_addr = "0x0000000000000000000000000000000000000000"
create2_factory_salt = "0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5"
EOF

# Clean up any broadcast files from forge
echo "Cleaning up broadcast files..."
cd ../..
rm -rf broadcast/DeployL1CoreContracts.s.sol 2>/dev/null || true
rm -rf broadcast/DeployCTM.s.sol 2>/dev/null || true
rm -rf broadcast/RegisterCTM.s.sol 2>/dev/null || true

# Also clean up cache-forge if it exists (can cause issues)
rm -rf cache-forge/DeployL1CoreContracts.s.sol 2>/dev/null || true
rm -rf cache-forge/DeployCTM.s.sol 2>/dev/null || true
rm -rf cache-forge/RegisterCTM.s.sol 2>/dev/null || true

cd test/anvil-interop

echo "✅ Broadcast and cache files cleaned"

# Verify testnet_verifier flag exists in config files
for config_file in config/l1-deployment.toml config/ctm-deployment.toml; do
    if [ -f "$config_file" ] && ! grep -q "testnet_verifier" "$config_file"; then
        echo "⚠️  Warning: testnet_verifier missing in $config_file"
    fi
done

echo "✅ Cleanup complete!"
echo "You can now run 'yarn start' fresh."
