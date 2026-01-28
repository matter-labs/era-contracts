#!/bin/bash

# Cleanup script for Anvil interop testing environment
# This script stops all Anvil instances and cleans up deployment artifacts
# while preserving the original configuration files

set -e

echo "🧹 Cleaning up Anvil interop environment..."

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

# Fallback: Kill any remaining anvil processes
pkill -9 -f "anvil" 2>/dev/null || true
sleep 1
pkill -9 anvil 2>/dev/null || true
sleep 1

# Stop any running ts-node processes from previous runs
pkill -9 -f "ts-node index.ts" 2>/dev/null || true
pkill -9 -f "ts-node step6-start-settler.ts" 2>/dev/null || true
pkill -9 -f "yarn start" 2>/dev/null || true
pkill -9 -f "yarn step6" 2>/dev/null || true

# Clean up step6 log file
rm -f /tmp/step6-output.log 2>/dev/null || true

# Final check
if pgrep -f "anvil" > /dev/null 2>&1; then
    echo "⚠️  Warning: Some Anvil processes are still running. Forcing kill..."
    pkill -9 -f "anvil" 2>/dev/null || true
    sleep 2
else
    echo "✅ All Anvil instances stopped"
fi

# Wait for ports to be released
sleep 2

# Create backup of config files before cleanup (to preserve testnet_verifier and other settings)
echo "Backing up configuration files..."
cp config/l1-deployment.toml config/l1-deployment.toml.backup 2>/dev/null || true
cp config/ctm-deployment.toml config/ctm-deployment.toml.backup 2>/dev/null || true

# Clean up output files
echo "Cleaning up output files..."
rm -rf outputs
mkdir -p outputs

# Reset permanent values to initial state (but preserve config settings)
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

cd scripts/anvil-interop

echo "✅ Broadcast and cache files cleaned"

# Restore the original config files to ensure testnet settings are preserved
# This prevents deployment scripts from potentially modifying or removing these settings
if [ -f config/l1-deployment.toml.backup ]; then
    # Extract critical fields from backup and ensure they're in the current config
    if grep -q "testnet_verifier" config/l1-deployment.toml.backup; then
        echo "Ensuring testnet_verifier flag is preserved in l1-deployment.toml..."
        # If testnet_verifier is missing, add it back from backup
        if ! grep -q "testnet_verifier" config/l1-deployment.toml; then
            # Add testnet_verifier flag at the top of the file if missing
            sed -i.tmp '1s/^/testnet_verifier = true\'$'\n/' config/l1-deployment.toml && rm -f config/l1-deployment.toml.tmp
        fi
    fi
    rm -f config/l1-deployment.toml.backup
fi

if [ -f config/ctm-deployment.toml.backup ]; then
    if grep -q "testnet_verifier" config/ctm-deployment.toml.backup; then
        echo "Ensuring testnet_verifier flag is preserved in ctm-deployment.toml..."
        if ! grep -q "testnet_verifier" config/ctm-deployment.toml; then
            sed -i.tmp '1s/^/testnet_verifier = true\'$'\n/' config/ctm-deployment.toml && rm -f config/ctm-deployment.toml.tmp
        fi
    fi
    rm -f config/ctm-deployment.toml.backup
fi

echo "✅ Cleanup complete! Configuration files preserved with testnet settings."
echo "You can now run 'yarn start' fresh."
