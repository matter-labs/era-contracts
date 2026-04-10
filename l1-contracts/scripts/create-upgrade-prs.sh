#!/bin/bash

# =============================================================================
# Create PRs in transaction-simulator and protocol-upgrade-verification-tool
# =============================================================================
#
# Usage:
#   ./scripts/create-upgrade-prs.sh \
#     --output-dir script-out/verifier-upgrade-stage-20260410-113731 \
#     --env stage \
#     --version v29.4
#
# Requires: gh CLI authenticated
# =============================================================================

set -euo pipefail

OUTPUT_DIR=""
ENV=""
VERSION=""

usage() {
    echo "Usage: $0 --output-dir <path> --env <stage|mainnet> --version <vX.Y>"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --env) ENV="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$OUTPUT_DIR" ] || [ -z "$ENV" ] || [ -z "$VERSION" ]; then
    echo "Error: --output-dir, --env, and --version are required"
    usage
fi

# Resolve to absolute path
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

DATE=$(date +%Y-%m-%d)
BRANCH_NAME="${DATE}-verifier-upgrade-${VERSION}-${ENV}"
TX_JSON="$OUTPUT_DIR/transactions.json"
ECOSYSTEM_TOML="$OUTPUT_DIR/ecosystem-output.toml"

if [ ! -f "$TX_JSON" ]; then
    echo "Error: $TX_JSON not found"
    exit 1
fi

if [ ! -f "$ECOSYSTEM_TOML" ]; then
    echo "Error: $ECOSYSTEM_TOML not found"
    exit 1
fi

TMPDIR=$(mktemp -d)
echo "Working directory: $TMPDIR"
echo ""

# ---- 1. transaction-simulator PR ----
echo "============================================================"
echo "  Creating PR in transaction-simulator"
echo "============================================================"

TX_SIM_DIR="$TMPDIR/transaction-simulator"
git clone https://github.com/matter-labs/transaction-simulator.git "$TX_SIM_DIR" 2>&1 | tail -2

cd "$TX_SIM_DIR"
git checkout -b "$BRANCH_NAME"

TX_FILENAME="${DATE}-${VERSION}-verifier-upgrade-${ENV}.json"
cp "$TX_JSON" "transactions/${TX_FILENAME}"

echo "Copied transactions -> transactions/${TX_FILENAME}"

# Generate decoded calldata using their tooling
echo "Installing dependencies..."
npm install --silent 2>&1 | tail -1

echo "Generating decoded calldata..."
yarn decode -f "transactions/${TX_FILENAME}" 2>&1 | tail -5 || echo "Warning: decoded calldata generation failed"

git add transactions/ decoded-calldata/
git commit --no-gpg-sign -m "${VERSION} verifier upgrade ${ENV} calldata"

git push --no-verify -u origin "$BRANCH_NAME" 2>&1 | tail -3

TX_SIM_PR_URL=$(gh pr create \
    --repo matter-labs/transaction-simulator \
    --head "$BRANCH_NAME" \
    --title "${VERSION} verifier upgrade ${ENV} calldata" \
    --body "$(cat <<EOF
## Summary
- Verifier-only emergency upgrade calldata for **${ENV}**
- Protocol version bump: ${VERSION}
- Generated automatically by \`run-verifier-upgrade.sh\`

## Transactions
- **stage0**: pause migrations, check upgrade readiness
- **stage1**: set chain creation params, set new version upgrade
- **stage2**: finish upgrade, unpause migrations, cleanup

Generated with [emergency-upgrade-tooling](https://github.com/vladbochok/emergency-upgrade-tooling)
EOF
)")

echo ""
echo "transaction-simulator PR: $TX_SIM_PR_URL"
echo ""

# ---- 2. protocol-upgrade-verification-tool PR ----
echo "============================================================"
echo "  Creating PR in protocol-upgrade-verification-tool"
echo "============================================================"

PUVT_DIR="$TMPDIR/protocol-upgrade-verification-tool"
git clone --depth 1 https://github.com/matter-labs/protocol-upgrade-verification-tool.git "$PUVT_DIR" 2>&1 | tail -2

cd "$PUVT_DIR"
git checkout -b "$BRANCH_NAME"

# Place ecosystem output in the right directory
PUVT_DATA_DIR="data/${VERSION}-verifier-upgrade/${ENV}"
mkdir -p "$PUVT_DATA_DIR"

# Check if YAML was already generated (from Step 3 of the main script)
YAML_FILE="$OUTPUT_DIR/upgrade.yaml"
if [ -f "$YAML_FILE" ] && [ -s "$YAML_FILE" ]; then
    cp "$YAML_FILE" "$PUVT_DATA_DIR/${VERSION}-ecosystem.yaml"
    echo "Copied YAML -> $PUVT_DATA_DIR/${VERSION}-ecosystem.yaml"
else
    cp "$ECOSYSTEM_TOML" "$PUVT_DATA_DIR/${VERSION}-ecosystem.toml"
    echo "Copied TOML -> $PUVT_DATA_DIR/${VERSION}-ecosystem.toml"
fi

git add data/
git commit --no-gpg-sign -m "${VERSION} verifier upgrade ${ENV} verification data"

git push --no-verify -u origin "$BRANCH_NAME" 2>&1 | tail -3

PUVT_PR_URL=$(gh pr create \
    --repo matter-labs/protocol-upgrade-verification-tool \
    --head "$BRANCH_NAME" \
    --title "${VERSION} verifier upgrade ${ENV}" \
    --body "$(cat <<EOF
## Summary
- Verification data for ${VERSION} verifier-only upgrade on **${ENV}**
- Contains ecosystem output with governance calldata, deployed addresses, and chain creation params

Generated with [emergency-upgrade-tooling](https://github.com/vladbochok/emergency-upgrade-tooling)
EOF
)")

echo ""
echo "protocol-upgrade-verification-tool PR: $PUVT_PR_URL"

# ---- Cleanup ----
echo ""
echo "============================================================"
echo "  Done!"
echo "============================================================"
echo ""
echo "  transaction-simulator PR:              $TX_SIM_PR_URL"
echo "  protocol-upgrade-verification-tool PR: $PUVT_PR_URL"
echo ""
echo "  Temp directory: $TMPDIR"
echo "  (You can delete it: rm -rf $TMPDIR)"
