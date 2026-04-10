#!/bin/bash

# =============================================================================
# Verifier-Only Upgrade: End-to-End Script
# =============================================================================
#
# Generates upgrade calldata for a verifier-only upgrade with minimal input.
# Reads all required data from on-chain state automatically.
#
# Usage:
#   PRIVATE_KEY=$PK ./run-verifier-upgrade.sh --env stage
#
# Required environment variables:
#   PRIVATE_KEY       - Deployer private key
#
# Optional environment variables:
#   L1_RPC_URL        - L1 RPC URL (has defaults per environment)
#   GATEWAY_RPC_URL   - Gateway RPC URL
#   PUVT_REPO         - Path to protocol-upgrade-verification-tool repo
#
# Examples:
#   # Stage (uses default Sepolia RPC):
#   PRIVATE_KEY=$TEST_PK ./run-verifier-upgrade.sh --env stage
#
#   # Mainnet with custom RPC:
#   PRIVATE_KEY=$DEPLOYER_PK \
#   L1_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/KEY \
#   ./run-verifier-upgrade.sh --env mainnet
#
#   # Dry run (show what would happen):
#   PRIVATE_KEY=$PK ./run-verifier-upgrade.sh --env stage --dry-run
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Parse arguments ----
ENV=""
SKIP_FORGE=false
DRY_RUN=false
INPUT_TOML=""

usage() {
    echo "Usage: $0 --env <stage|mainnet> [--input-toml <path>] [--skip-forge] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --env           Environment: stage or mainnet (required)"
    echo "  --input-toml    Use existing TOML instead of generating from chain"
    echo "  --skip-forge    Skip forge script (only generate TOML)"
    echo "  --dry-run       Show what would be done without executing"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --input-toml) INPUT_TOML="$2"; shift 2 ;;
        --skip-forge) SKIP_FORGE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Error: --env is required"
    usage
fi

# ---- Set defaults per environment ----
if [ "$ENV" = "stage" ]; then
    L1_RPC_URL="${L1_RPC_URL:-https://gateway.tenderly.co/public/sepolia}"
    CHAIN_ID=11155111
elif [ "$ENV" = "mainnet" ]; then
    L1_RPC_URL="${L1_RPC_URL:-https://gateway.tenderly.co/public/mainnet}"
    CHAIN_ID=1
else
    echo "Error: --env must be 'stage' or 'mainnet'"
    exit 1
fi

if [ -z "${PRIVATE_KEY:-}" ] && [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ]; then
    echo "Error: PRIVATE_KEY environment variable is required"
    exit 1
fi

echo "============================================================"
echo "  Verifier-Only Upgrade Pipeline"
echo "============================================================"
echo ""
echo "  Environment:  $ENV"
echo "  L1 RPC:       $L1_RPC_URL"
echo "  L1 Chain ID:  $CHAIN_ID"
echo ""

# ---- Output directories ----
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="script-out/verifier-upgrade-${ENV}-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

UPGRADE_INPUT_TOML="$OUTPUT_DIR/upgrade-input.toml"
ECOSYSTEM_OUTPUT="$OUTPUT_DIR/ecosystem-output.toml"
YAML_OUTPUT="$OUTPUT_DIR/upgrade.yaml"

# ---- Step 1: Generate upgrade TOML from on-chain state ----
echo "============================================================"
echo "  Step 1: Generate upgrade TOML from on-chain state"
echo "============================================================"

if [ -n "$INPUT_TOML" ]; then
    echo "Using provided TOML: $INPUT_TOML"
    cp "$INPUT_TOML" "$UPGRADE_INPUT_TOML"
else
    GW_ARGS=""
    if [ -n "${GATEWAY_RPC_URL:-}" ]; then
        GW_ARGS="--gateway-rpc $GATEWAY_RPC_URL"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would generate TOML from on-chain state for $ENV"
    else
        yarn ts-node scripts/generate-verifier-upgrade-toml.ts \
            --env "$ENV" \
            --l1-rpc "$L1_RPC_URL" \
            $GW_ARGS \
            --output "$UPGRADE_INPUT_TOML"

        echo ""
        echo "Generated: $UPGRADE_INPUT_TOML"
    fi
fi

echo ""

# ---- Step 2: Run forge script ----
if [ "$SKIP_FORGE" = false ]; then
    echo "============================================================"
    echo "  Step 2: Deploy verifiers & generate calldata"
    echo "============================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run forge script with:"
        echo "  Input:  $UPGRADE_INPUT_TOML"
        echo "  Output: $ECOSYSTEM_OUTPUT"
    else
        FORGE_EXIT=0
        UPGRADE_ECOSYSTEM_INPUT="$UPGRADE_INPUT_TOML" \
        UPGRADE_ECOSYSTEM_OUTPUT="$ECOSYSTEM_OUTPUT" \
        forge script --sig "run()" \
            ./deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol:VerifierOnlyUpgrade \
            --ffi \
            --rpc-url "$L1_RPC_URL" \
            --gas-limit 20000000000 \
            --private-key "$PRIVATE_KEY" \
            --broadcast || FORGE_EXIT=$?

        if [ "$FORGE_EXIT" -ne 0 ]; then
            if [ -f "$ECOSYSTEM_OUTPUT" ]; then
                echo ""
                echo "Warning: forge broadcast failed (exit code $FORGE_EXIT)"
                echo "  This usually means the deployer account has insufficient funds."
                echo "  The simulation succeeded and output was written."
                echo "  Fund the deployer and re-run, or use the simulation output."
            else
                echo "Error: forge script failed and no output was generated."
                exit 1
            fi
        fi

        echo ""
        echo "Forge output: $ECOSYSTEM_OUTPUT"
    fi
else
    echo "Skipping forge script (--skip-forge)"
fi

echo ""

# ---- Step 3: Generate YAML output ----
if [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ]; then
    echo "============================================================"
    echo "  Step 3: Generate YAML output"
    echo "============================================================"

    BROADCAST_FILE="broadcast/VerifierOnlyUpgrade.s.sol/${CHAIN_ID}/run-latest.json"

    PUVT_ARGS=""
    if [ -n "${PUVT_REPO:-}" ]; then
        PUVT_ARGS="--puvt-repo $PUVT_REPO"
    fi

    UPGRADE_ECOSYSTEM_OUTPUT="$ECOSYSTEM_OUTPUT" \
    UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS="$BROADCAST_FILE" \
    YAML_OUTPUT_FILE="$YAML_OUTPUT" \
    UPGRADE_SEMVER="verifier" \
    UPGRADE_NAME="vk-update" \
    UPGRADE_ENV="$ENV" \
    yarn upgrade-yaml-output-generator $PUVT_ARGS || echo "Warning: YAML generation failed"

    echo ""
fi

# ---- Summary ----
echo "============================================================"
echo "  Done!"
echo "============================================================"
echo ""
echo "  Output directory: $OUTPUT_DIR"
echo ""
echo "  Files:"
echo "    Input TOML:     $UPGRADE_INPUT_TOML"
if [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ]; then
echo "    Ecosystem TOML: $ECOSYSTEM_OUTPUT"
echo "    YAML:           $YAML_OUTPUT"
echo "    Broadcast:      broadcast/VerifierOnlyUpgrade.s.sol/${CHAIN_ID}/run-latest.json"
fi
echo ""
echo "  Next steps:"
echo "    1. Review the generated calldata"
echo "    2. Copy to transaction-simulator and create PR"
echo "    3. Run simulation"
echo "    4. Submit to governance / Security Council"
