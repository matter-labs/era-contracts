#!/bin/bash

# Verify and fix configuration files before starting
# This ensures testnet_verifier is always present

set -e

echo "🔍 Verifying configuration files..."

CONFIG_DIR="$(dirname "$0")/config"
L1_CONFIG="$CONFIG_DIR/l1-deployment.toml"
CTM_CONFIG="$CONFIG_DIR/ctm-deployment.toml"

# Function to ensure testnet_verifier exists at the top of the file
ensure_testnet_flag() {
    local config_file=$1
    local config_name=$2

    if [ ! -f "$config_file" ]; then
        echo "❌ Error: $config_name not found at $config_file"
        exit 1
    fi

    if ! grep -q "testnet_verifier" "$config_file"; then
        echo "⚠️  testnet_verifier missing in $config_name, adding it..."
        # Create a temp file with testnet_verifier at the top
        {
            echo "era_chain_id = 270"
            echo "owner_address = \"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\""
            echo "testnet_verifier = true"
            echo "support_l2_legacy_shared_bridge_test = false"
            echo ""
            # Skip the first few lines if they contain era_chain_id, owner_address, etc.
            grep -v "^era_chain_id\|^owner_address\|^support_l2_legacy_shared_bridge_test" "$config_file" || true
        } > "$config_file.tmp"
        mv "$config_file.tmp" "$config_file"
        echo "✅ testnet_verifier added to $config_name"
    else
        echo "✅ $config_name has testnet_verifier"
    fi
}

# Check and fix L1 config
ensure_testnet_flag "$L1_CONFIG" "l1-deployment.toml"

# Check and fix CTM config
ensure_testnet_flag "$CTM_CONFIG" "ctm-deployment.toml"

echo "✅ Configuration verification complete!"
