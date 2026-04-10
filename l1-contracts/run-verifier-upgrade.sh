#!/bin/bash

# =============================================================================
# Verifier-Only Upgrade: End-to-End Script
# =============================================================================
#
# This script runs the full pipeline for a verifier-only upgrade:
#   1. Prepare the upgrade TOML (bump versions, fetch chain creation params)
#   2. Run the forge script (deploy new verifiers, generate governance calldata)
#   3. Generate YAML output (for transaction-simulator and PUVT)
#
# Usage:
#   ./run-verifier-upgrade.sh --env <stage|mainnet> --prev-toml <path> [options]
#
# Required environment variables:
#   PRIVATE_KEY       - Deployer private key
#   L1_RPC_URL        - L1 RPC URL
#
# Optional environment variables:
#   GATEWAY_RPC_URL   - Gateway RPC URL (for gateway chain creation params)
#   PUVT_REPO         - Path to protocol-upgrade-verification-tool repo
#
# Examples:
#   # Stage (Sepolia):
#   L1_RPC_URL=https://gateway.tenderly.co/public/sepolia \
#   GATEWAY_RPC_URL=$GATEWAY_STAGE \
#   PRIVATE_KEY=$TEST_PK \
#   ./run-verifier-upgrade.sh \
#     --env stage \
#     --prev-toml upgrade-envs/v0.29.3-vk-update/stage.toml
#
#   # Mainnet:
#   L1_RPC_URL=https://gateway.tenderly.co/public/mainnet \
#   GATEWAY_RPC_URL=$GATEWAY_MAINNET \
#   PRIVATE_KEY=$DEPLOYER_PK \
#   ./run-verifier-upgrade.sh \
#     --env mainnet \
#     --prev-toml upgrade-envs/v0.29.4-vk-update/mainnet.toml
# =============================================================================

set -euo pipefail

# ---- Parse arguments ----
ENV=""
PREV_TOML=""
UPGRADE_NAME="vk-update"
SKIP_PREPARE=false
SKIP_FORGE=false
DRY_RUN=false

usage() {
    echo "Usage: $0 --env <stage|mainnet> --prev-toml <path> [--upgrade-name <name>] [--skip-prepare] [--skip-forge] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --env           Environment: stage or mainnet"
    echo "  --prev-toml     Path to previous upgrade TOML (relative to l1-contracts/)"
    echo "  --upgrade-name  Upgrade name suffix (default: vk-update)"
    echo "  --skip-prepare  Skip TOML preparation (use if you already have the input TOML)"
    echo "  --skip-forge    Skip forge script (only generate YAML from existing output)"
    echo "  --dry-run       Show what would be done without executing"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --prev-toml) PREV_TOML="$2"; shift 2 ;;
        --upgrade-name) UPGRADE_NAME="$2"; shift 2 ;;
        --skip-prepare) SKIP_PREPARE=true; shift ;;
        --skip-forge) SKIP_FORGE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Error: --env is required"
    usage
fi

if [ -z "$PREV_TOML" ] && [ "$SKIP_PREPARE" = false ]; then
    echo "Error: --prev-toml is required (or use --skip-prepare)"
    usage
fi

# ---- Validate environment variables ----
if [ -z "${L1_RPC_URL:-}" ]; then
    echo "Error: L1_RPC_URL environment variable is required"
    exit 1
fi

if [ -z "${PRIVATE_KEY:-}" ] && [ "$SKIP_FORGE" = false ]; then
    echo "Error: PRIVATE_KEY environment variable is required (or use --skip-forge)"
    exit 1
fi

# ---- Derive paths ----
# Extract version from previous TOML path (e.g., v0.29.3 -> next is v0.29.4)
# Or let the user specify
PREV_VERSION=$(echo "$PREV_TOML" | grep -oP 'v[\d.]+' | head -1 || true)

# Determine RPC URL based on environment
if [ "$ENV" = "stage" ]; then
    RPC_URL="${L1_RPC_URL}"
    CHAIN_ID=11155111  # Sepolia
elif [ "$ENV" = "mainnet" ]; then
    RPC_URL="${L1_RPC_URL}"
    CHAIN_ID=1
else
    echo "Error: --env must be 'stage' or 'mainnet'"
    exit 1
fi

echo "============================================================"
echo "  Verifier-Only Upgrade Pipeline"
echo "============================================================"
echo ""
echo "  Environment:  $ENV"
echo "  RPC URL:      $RPC_URL"
echo "  Chain ID:     $CHAIN_ID"
echo "  Prev TOML:    $PREV_TOML"
echo "  Upgrade name: $UPGRADE_NAME"
echo ""

# ---- Step 1: Prepare upgrade TOML ----
if [ "$SKIP_PREPARE" = false ]; then
    echo "============================================================"
    echo "  Step 1: Prepare upgrade TOML"
    echo "============================================================"

    # Determine output path based on prev toml
    # Replace version in path with "new" temporarily
    UPGRADE_INPUT_DIR="upgrade-envs/new-${UPGRADE_NAME}"
    mkdir -p "$UPGRADE_INPUT_DIR"
    UPGRADE_INPUT_TOML="$UPGRADE_INPUT_DIR/${ENV}.toml"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: ./scripts/prepare-upgrade-toml.sh $PREV_TOML $UPGRADE_INPUT_TOML"
    else
        ./scripts/prepare-upgrade-toml.sh "$PREV_TOML" "$UPGRADE_INPUT_TOML"
    fi
else
    echo "Skipping TOML preparation (--skip-prepare)"
    # When skipping, use prev-toml as input directly
    UPGRADE_INPUT_TOML="$PREV_TOML"
fi

echo ""

# ---- Step 2: Run forge script ----
SCRIPT_OUTPUT_DIR="script-out"
mkdir -p "$SCRIPT_OUTPUT_DIR"
ECOSYSTEM_OUTPUT="$SCRIPT_OUTPUT_DIR/verifier-upgrade-ecosystem.toml"

if [ "$SKIP_FORGE" = false ]; then
    echo "============================================================"
    echo "  Step 2: Deploy verifiers & generate calldata (forge)"
    echo "============================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run forge script with:"
        echo "  UPGRADE_ECOSYSTEM_INPUT=$UPGRADE_INPUT_TOML"
        echo "  UPGRADE_ECOSYSTEM_OUTPUT=$ECOSYSTEM_OUTPUT"
    else
        UPGRADE_ECOSYSTEM_INPUT="$UPGRADE_INPUT_TOML" \
        UPGRADE_ECOSYSTEM_OUTPUT="$ECOSYSTEM_OUTPUT" \
        forge script --sig "run()" \
            ./deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol:VerifierOnlyUpgrade \
            --ffi \
            --rpc-url "$RPC_URL" \
            --gas-limit 20000000000 \
            --private-key "$PRIVATE_KEY" \
            --broadcast

        echo ""
        echo "Forge script output: $ECOSYSTEM_OUTPUT"
    fi
else
    echo "Skipping forge script (--skip-forge)"
fi

echo ""

# ---- Step 3: Generate YAML output ----
echo "============================================================"
echo "  Step 3: Generate YAML output"
echo "============================================================"

BROADCAST_FILE="broadcast/VerifierOnlyUpgrade.s.sol/${CHAIN_ID}/run-latest.json"
YAML_OUTPUT="$SCRIPT_OUTPUT_DIR/yaml-output.yaml"

# Determine semver from the ecosystem output
UPGRADE_SEMVER="${PREV_VERSION:-unknown}"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would run upgrade-yaml-output-generator with:"
    echo "  UPGRADE_ECOSYSTEM_OUTPUT=$ECOSYSTEM_OUTPUT"
    echo "  UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=$BROADCAST_FILE"
    echo "  YAML_OUTPUT_FILE=$YAML_OUTPUT"
    echo "  UPGRADE_SEMVER=$UPGRADE_SEMVER"
    echo "  UPGRADE_NAME=$UPGRADE_NAME"
    echo "  UPGRADE_ENV=$ENV"
else
    PUVT_ARGS=""
    if [ -n "${PUVT_REPO:-}" ]; then
        PUVT_ARGS="--puvt-repo $PUVT_REPO"
    fi

    UPGRADE_ECOSYSTEM_OUTPUT="$ECOSYSTEM_OUTPUT" \
    UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS="$BROADCAST_FILE" \
    YAML_OUTPUT_FILE="$YAML_OUTPUT" \
    UPGRADE_SEMVER="$UPGRADE_SEMVER" \
    UPGRADE_NAME="$UPGRADE_NAME" \
    UPGRADE_ENV="$ENV" \
    yarn upgrade-yaml-output-generator $PUVT_ARGS

    echo ""
    echo "YAML output: $YAML_OUTPUT"
fi

echo ""
echo "============================================================"
echo "  Done!"
echo "============================================================"
echo ""
echo "Outputs:"
echo "  Ecosystem TOML: $ECOSYSTEM_OUTPUT"
echo "  Broadcast JSON: $BROADCAST_FILE"
echo "  YAML output:    $YAML_OUTPUT"
echo ""
echo "Next steps:"
echo "  1. Review the generated calldata in $YAML_OUTPUT"
echo "  2. Copy YAML to transaction-simulator repo"
echo "  3. Run simulation: yarn simulate"
echo "  4. Submit to governance / Security Council"
