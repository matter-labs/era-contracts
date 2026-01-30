#!/bin/bash

# Prepare a new upgrade TOML file from a previous one
# Usage: ./prepare-upgrade-toml.sh <input-toml> <output-toml> [--dry-run]
#
# Environment variables:
#   L1_RPC_URL - L1 RPC URL (required)
#   GATEWAY_RPC_URL - Gateway RPC URL (optional, for gateway params)

set -e

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <input-toml> <output-toml> [--dry-run]"
    echo ""
    echo "Environment variables:"
    echo "  L1_RPC_URL      - L1 RPC URL (required)"
    echo "  GATEWAY_RPC_URL - Gateway RPC URL (optional)"
    exit 1
fi

INPUT="$1"
OUTPUT="$2"
DRY_RUN=false

if [ "$3" == "--dry-run" ]; then
    DRY_RUN=true
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: Input file not found: $INPUT"
    exit 1
fi

if [ -z "$L1_RPC_URL" ]; then
    echo "Error: L1_RPC_URL environment variable is required"
    exit 1
fi

# Extract values from input TOML
LATEST_HEX=$(sed -n '/^\[contracts\]/,/^\[/p' "$INPUT" | grep "^latest_protocol_version" | sed 's/.*= *//' | tr -d ' ')
OLD_HEX=$(sed -n '1,/^\[/p' "$INPUT" | grep "^old_protocol_version" | sed 's/.*= *//' | tr -d ' ')
OLD_SALT=$(sed -n '/^\[contracts\]/,/^\[/p' "$INPUT" | grep "^create2_factory_salt" | sed 's/.*= *"//' | sed 's/".*//')
BRIDGEHUB=$(sed -n '/^\[contracts\]/,/^\[/p' "$INPUT" | grep "^bridgehub_proxy_address" | sed 's/.*= *"//' | sed 's/".*//')
ERA_CHAIN_ID=$(grep "^era_chain_id" "$INPUT" | sed 's/.*= *//' | tr -d ' ')

if [ -z "$LATEST_HEX" ]; then
    echo "Error: Could not find latest_protocol_version in [contracts] section"
    exit 1
fi

if [ -z "$BRIDGEHUB" ]; then
    echo "Error: Could not find bridgehub_proxy_address in [contracts] section"
    exit 1
fi

if [ -z "$ERA_CHAIN_ID" ]; then
    echo "Error: Could not find era_chain_id"
    exit 1
fi

# Convert hex to decimal, increment, convert back
LATEST_DEC=$((LATEST_HEX))
NEW_OLD_DEC=$LATEST_DEC
NEW_LATEST_DEC=$((LATEST_DEC + 1))

NEW_OLD_HEX=$(printf "0x%x" $NEW_OLD_DEC)
NEW_LATEST_HEX=$(printf "0x%x" $NEW_LATEST_DEC)

# Generate random salt
NEW_SALT="0x$(openssl rand -hex 32)"

echo "============================================================"
echo "Preparing new upgrade TOML"
echo "============================================================"
echo ""
echo "Input file:  $INPUT"
echo "Output file: $OUTPUT"
echo ""
echo "Changes:"
echo "  old_protocol_version:    ${OLD_HEX:-(not set)} -> $NEW_OLD_HEX"
echo "  latest_protocol_version: $LATEST_HEX -> $NEW_LATEST_HEX"
echo "  create2_factory_salt:    ${OLD_SALT:-(not set)} -> $NEW_SALT"
echo "  governance_upgrade_timer_initial_delay: -> 0"
echo ""

# Create output directory if needed
mkdir -p "$(dirname "$OUTPUT")"

# Copy and modify file
cp "$INPUT" "$OUTPUT"

# Update old_protocol_version at root
if grep -q "^old_protocol_version" "$OUTPUT"; then
    sed -i.bak "s/^old_protocol_version.*/old_protocol_version = $NEW_OLD_HEX/" "$OUTPUT"
else
    sed -i.bak "/^era_chain_id/a\\
old_protocol_version = $NEW_OLD_HEX" "$OUTPUT"
fi

# Update latest_protocol_version in [contracts] section
sed -i.bak "s/^latest_protocol_version.*/latest_protocol_version = $NEW_LATEST_HEX/" "$OUTPUT"

# Update create2_factory_salt in [contracts] section
sed -i.bak "s/^create2_factory_salt.*/create2_factory_salt = \"$NEW_SALT\"/" "$OUTPUT"

# Set governance_upgrade_timer_initial_delay to 0
sed -i.bak "s/^governance_upgrade_timer_initial_delay.*/governance_upgrade_timer_initial_delay = 0/" "$OUTPUT"

# Remove [old_chain_creation_params] sections (everything from first occurrence to EOF)
if grep -q "^\[old_chain_creation_params" "$OUTPUT"; then
    echo "Removing [old_chain_creation_params] sections"
    sed -i.bak '/^\[old_chain_creation_params/,$d' "$OUTPUT"
fi

# Clean up backup files
rm -f "$OUTPUT.bak"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "Dry run - output would be:"
    echo "------------------------------------------------------------"
    cat "$OUTPUT"
    echo "------------------------------------------------------------"
    rm -f "$OUTPUT"
    exit 0
fi

echo "Created: $OUTPUT"
echo ""

# Fetch and append old_chain_creation_params
echo "============================================================"
echo "Fetching old_chain_creation_params"
echo "============================================================"

readonly OLD_CHAIN_CREATION_PARAMS_TOML='chain-creation-params.toml'

yarn ts-node scripts/fetch-chain-creation-params.ts \
  --bridgehub "$BRIDGEHUB_ADDRESS" \
  --era-chain-id "$ERA_CHAIN_ID" \
  --l1-rpc "$L1_RPC_URL" \
  --gateway-rpc "$GW_RPC_URL" \
  --output "$OLD_CHAIN_CREATION_PARAMS_TOML"

cat "$OLD_CHAIN_CREATION_PARAMS_TOML" >> "$OUTPUT"
rm "$OLD_CHAIN_CREATION_PARAMS_TOML"

echo ""
echo "Done! Output file: $OUTPUT"
