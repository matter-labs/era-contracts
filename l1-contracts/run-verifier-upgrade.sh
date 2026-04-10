#!/bin/bash

# =============================================================================
# Verifier-Only Upgrade: End-to-End Script
# =============================================================================
#
# Generates upgrade calldata for a verifier-only upgrade with minimal input.
# Reads all required data from on-chain state automatically.
# Deploys verifier contracts from a specified era-contracts branch/commit.
#
# Usage:
#   PRIVATE_KEY=$PK ./run-verifier-upgrade.sh \
#     --env stage \
#     --contracts-ref vb-new-verifier-keys
#
# Required:
#   --env              stage or mainnet
#   --contracts-ref    Branch or commit in era-contracts with updated Verifier.sol
#   PRIVATE_KEY        Deployer private key (env var)
#
# Optional:
#   L1_RPC_URL         L1 RPC URL (defaults per environment)
#   GATEWAY_RPC_URL    Gateway RPC URL
#   --create-prs       Create PRs in transaction-simulator and PUVT
#   --version          Override auto-detected version (e.g. v29.4)
#   --contracts-repo   Git remote URL (default: matter-labs/era-contracts)
#   --skip-forge       Skip forge script (only generate TOML)
#   --dry-run          Show what would be done without executing
#
# Examples:
#   # Full pipeline on stage:
#   PRIVATE_KEY=$PK ./run-verifier-upgrade.sh \
#     --env stage \
#     --contracts-ref vb-new-verifier-keys \
#     --create-prs
#
#   # Mainnet from a specific commit:
#   PRIVATE_KEY=$PK ./run-verifier-upgrade.sh \
#     --env mainnet \
#     --contracts-ref a1b2c3d4
# =============================================================================

set -euo pipefail

# ---- Parse arguments ----
ENV=""
CONTRACTS_REF=""
CONTRACTS_REPO="https://github.com/matter-labs/era-contracts.git"
SKIP_FORGE=false
DRY_RUN=false
INPUT_TOML=""
CREATE_PRS=false
UPGRADE_VERSION=""

usage() {
    echo "Usage: $0 --env <stage|mainnet> --contracts-ref <branch|commit> [options]"
    echo ""
    echo "Required:"
    echo "  --env             Environment: stage or mainnet"
    echo "  --contracts-ref   Branch or commit with updated Verifier contracts"
    echo ""
    echo "Optional:"
    echo "  --contracts-repo  Git remote URL (default: matter-labs/era-contracts)"
    echo "  --input-toml      Use existing TOML instead of generating from chain"
    echo "  --skip-forge      Skip forge script (only generate TOML)"
    echo "  --dry-run         Show what would be done without executing"
    echo "  --create-prs      Create PRs in transaction-simulator and PUVT"
    echo "  --version         Override auto-detected upgrade version (e.g. v29.4)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --contracts-ref) CONTRACTS_REF="$2"; shift 2 ;;
        --contracts-repo) CONTRACTS_REPO="$2"; shift 2 ;;
        --input-toml) INPUT_TOML="$2"; shift 2 ;;
        --skip-forge) SKIP_FORGE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --create-prs) CREATE_PRS=true; shift ;;
        --version) UPGRADE_VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Error: --env is required"
    usage
fi

if [ -z "$CONTRACTS_REF" ]; then
    echo "Error: --contracts-ref is required"
    echo ""
    echo "  This is the branch or commit in era-contracts that contains the"
    echo "  updated Verifier.sol contracts with new verification keys."
    echo ""
    echo "  Example: --contracts-ref vb-new-verifier-keys"
    echo "  Example: --contracts-ref a1b2c3d4e5f6"
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

# ---- Output directories ----
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="script-out/verifier-upgrade-${ENV}-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "============================================================"
echo "  Verifier-Only Upgrade Pipeline"
echo "============================================================"
echo ""
echo "  Environment:    $ENV"
echo "  L1 RPC:         $L1_RPC_URL"
echo "  L1 Chain ID:    $CHAIN_ID"
echo "  Contracts ref:  $CONTRACTS_REF"
echo "  Contracts repo: $CONTRACTS_REPO"
echo "  Output dir:     $OUTPUT_DIR"
echo ""

# ---- Step 0: Clone era-contracts at the specified ref ----
echo "============================================================"
echo "  Step 0: Checkout era-contracts @ ${CONTRACTS_REF}"
echo "============================================================"

CONTRACTS_DIR="$OUTPUT_DIR/era-contracts"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would clone $CONTRACTS_REPO @ $CONTRACTS_REF"
else
    git clone "$CONTRACTS_REPO" "$CONTRACTS_DIR" 2>&1 | tail -2
    cd "$CONTRACTS_DIR"
    git checkout "$CONTRACTS_REF" 2>&1 | tail -2

    CONTRACTS_COMMIT=$(git rev-parse HEAD)
    CONTRACTS_SHORT=$(git rev-parse --short HEAD)
    echo ""
    echo "  Checked out: $CONTRACTS_COMMIT"
    echo "  Branch/tag:  $(git describe --all --always 2>/dev/null || echo "$CONTRACTS_REF")"

    # Save commit info for reproducibility
    echo "$CONTRACTS_COMMIT" > "$OUTPUT_DIR/contracts-commit.txt"
    echo "  Saved commit hash to $OUTPUT_DIR/contracts-commit.txt"

    # Verify Verifier contracts exist
    if [ ! -f "l1-contracts/contracts/state-transition/verifiers/L1VerifierFflonk.sol" ]; then
        echo ""
        echo "Error: L1VerifierFflonk.sol not found at ref $CONTRACTS_REF"
        echo "  Make sure this branch has the updated Verifier contracts."
        exit 1
    fi

    WORK_DIR="$CONTRACTS_DIR/l1-contracts"

    # Copy our scripts into the cloned repo if they don't exist there
    SCRIPT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in generate-verifier-upgrade-toml.ts generate-transaction-simulator-json.ts fetch-chain-creation-params.ts; do
        if [ ! -f "$WORK_DIR/scripts/$f" ] && [ -f "$SCRIPT_SRC_DIR/scripts/$f" ]; then
            cp "$SCRIPT_SRC_DIR/scripts/$f" "$WORK_DIR/scripts/$f"
            echo "  Copied $f into cloned repo"
        fi
    done
    if [ ! -f "$WORK_DIR/deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol" ] && [ -f "$SCRIPT_SRC_DIR/deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol" ]; then
        cp "$SCRIPT_SRC_DIR/deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol" "$WORK_DIR/deploy-scripts/upgrade/VerifierOnlyUpgrade.s.sol"
        echo "  Copied VerifierOnlyUpgrade.s.sol into cloned repo"
    fi
    if [ ! -f "$WORK_DIR/scripts/create-upgrade-prs.sh" ] && [ -f "$SCRIPT_SRC_DIR/scripts/create-upgrade-prs.sh" ]; then
        cp "$SCRIPT_SRC_DIR/scripts/create-upgrade-prs.sh" "$WORK_DIR/scripts/create-upgrade-prs.sh"
        chmod +x "$WORK_DIR/scripts/create-upgrade-prs.sh"
    fi

    # Build L2 contracts and system contracts if needed

    if [ ! -d "$CONTRACTS_DIR/l2-contracts/zkout" ]; then
        echo ""
        echo "  Building l2-contracts..."
        cd "$CONTRACTS_DIR/l2-contracts"
        yarn install --frozen-lockfile 2>&1 | tail -1
        forge build --zksync 2>&1 | tail -2
    fi

    if [ ! -d "$CONTRACTS_DIR/system-contracts/zkout" ]; then
        echo ""
        echo "  Building system-contracts..."
        cd "$CONTRACTS_DIR/system-contracts"
        yarn install --frozen-lockfile 2>&1 | tail -1
        yarn build:foundry 2>&1 | tail -2
    fi

    cd "$WORK_DIR"
    yarn install --frozen-lockfile 2>&1 | tail -1
fi

echo ""

# ---- Step 1: Generate upgrade TOML from on-chain state ----
UPGRADE_INPUT_TOML="$OUTPUT_DIR/upgrade-input.toml"
ECOSYSTEM_OUTPUT="$OUTPUT_DIR/ecosystem-output.toml"
YAML_OUTPUT="$OUTPUT_DIR/upgrade.yaml"

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
        TOML_OUTPUT=$(yarn --silent ts-node scripts/generate-verifier-upgrade-toml.ts \
            --env "$ENV" \
            --l1-rpc "$L1_RPC_URL" \
            $GW_ARGS \
            --output "$UPGRADE_INPUT_TOML" 2>&1)
        echo "$TOML_OUTPUT"

        # Extract auto-detected version if not provided via --version
        if [ -z "$UPGRADE_VERSION" ]; then
            UPGRADE_VERSION=$(echo "$TOML_OUTPUT" | grep '^UPGRADE_VERSION=' | cut -d= -f2)
            echo "  Auto-detected version: $UPGRADE_VERSION"
        fi

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
    echo "  Deploying from: $CONTRACTS_REPO @ ${CONTRACTS_SHORT:-$CONTRACTS_REF}"

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
if [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ] && [ -f "$ECOSYSTEM_OUTPUT" ]; then
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
    UPGRADE_SEMVER="${UPGRADE_VERSION:-verifier}" \
    UPGRADE_NAME="vk-update" \
    UPGRADE_ENV="$ENV" \
    yarn upgrade-yaml-output-generator $PUVT_ARGS || echo "Warning: YAML generation failed"

    echo ""
fi

# ---- Step 4: Generate transaction-simulator JSON ----
TX_SIM_JSON="$OUTPUT_DIR/transactions.json"

if [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ] && [ -f "$ECOSYSTEM_OUTPUT" ]; then
    echo "============================================================"
    echo "  Step 4: Generate transaction-simulator JSON"
    echo "============================================================"

    yarn ts-node scripts/generate-transaction-simulator-json.ts \
        --ecosystem-output "$ECOSYSTEM_OUTPUT" \
        --env "$ENV" \
        --output "$TX_SIM_JSON" \
        --upgrade-name "verifier-upgrade" || echo "Warning: transaction-simulator JSON generation failed"

    echo ""
fi

# ---- Step 5: Create PRs ----
if [ "$CREATE_PRS" = true ] && [ "$DRY_RUN" = false ] && [ -f "$TX_SIM_JSON" ]; then
    echo "============================================================"
    echo "  Step 5: Create PRs"
    echo "============================================================"

    ./scripts/create-upgrade-prs.sh \
        --output-dir "$OUTPUT_DIR" \
        --env "$ENV" \
        --version "$UPGRADE_VERSION"

    echo ""
fi

# ---- Summary ----
echo "============================================================"
echo "  Done!"
echo "============================================================"
echo ""
echo "  Output directory: $OUTPUT_DIR"
echo "  Contracts:        $CONTRACTS_REPO @ ${CONTRACTS_SHORT:-$CONTRACTS_REF}"
if [ -n "$UPGRADE_VERSION" ]; then
echo "  Version:          $UPGRADE_VERSION"
fi
echo ""
echo "  Files:"
echo "    Input TOML:     $UPGRADE_INPUT_TOML"
if [ "$SKIP_FORGE" = false ] && [ "$DRY_RUN" = false ] && [ -f "${ECOSYSTEM_OUTPUT:-}" ]; then
echo "    Ecosystem TOML: $ECOSYSTEM_OUTPUT"
echo "    TX simulator:   $TX_SIM_JSON"
echo "    Contracts ref:  $OUTPUT_DIR/contracts-commit.txt"
fi
echo ""
echo "  Next steps:"
echo "    1. Review the generated calldata"
echo "    2. Verify the contracts commit matches the expected Verifier update"
echo "    3. Submit to governance / Security Council"
