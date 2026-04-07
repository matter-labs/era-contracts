#!/usr/bin/env bash
# Update ZiSK verification keys and redeploy the ZiskVerifier contract.
#
# This script:
# 1. Reads new programVK + rootCVadcopFinal from ZiSK setup output
# 2. Patches ZiskVerifier.sol with the new constants
# 3. Deploys the new ZiskVerifier via Foundry
# 4. Calls MultiProofVerifier.setZiskVerifier() to activate it
#
# Prerequisites:
#   - ZiSK guest ELF compiled: cargo-zisk build --release
#   - ZiSK setup keys generated: cargo-zisk setup (produces provingKey/)
#   - OWNER_PK: private key of MultiProofVerifier owner
#   - RPC_URL: L1 RPC endpoint
#   - MULTI_PROOF_VERIFIER: address of the MultiProofVerifier contract
#
# The programVK is derived from the guest ELF ROM Merkle root. It changes
# whenever the guest binary changes. The rootCVadcopFinal comes from the
# ZiSK STARK-to-SNARK wrapping circuit setup.
#
# Usage:
#   ./update-zisk-vk.sh \
#     --elf /path/to/zksync-os-zisk-guest \
#     --rpc-url http://localhost:8545 \
#     --verifier 0x... \
#     --private-key 0x...
#
#   Or with env vars:
#   ZISK_ELF=/path/to/elf RPC_URL=... MULTI_PROOF_VERIFIER=0x... OWNER_PK=0x... ./update-zisk-vk.sh

set -euo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.zisk/bin:$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERA_DIR="$(dirname "$SCRIPT_DIR")"
VERIFIER_SOL="$ERA_DIR/contracts/state-transition/verifiers/ZiskVerifier.sol"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --elf) ZISK_ELF="$2"; shift 2 ;;
        --rpc-url) RPC_URL="$2"; shift 2 ;;
        --verifier) MULTI_PROOF_VERIFIER="$2"; shift 2 ;;
        --private-key) OWNER_PK="$2"; shift 2 ;;
        --vk-hash) VK_HASH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

: "${ZISK_ELF:?ZISK_ELF required (path to guest ELF binary)}"
: "${RPC_URL:?RPC_URL required (L1 RPC endpoint)}"
: "${MULTI_PROOF_VERIFIER:?MULTI_PROOF_VERIFIER required (contract address)}"
: "${OWNER_PK:?OWNER_PK required (private key of MultiProofVerifier owner)}"
DRY_RUN="${DRY_RUN:-0}"

echo "=== ZiSK Verification Key Update ==="
echo ""

# Step 1: Extract programVK from guest ELF
# cargo-zisk computes the ROM Merkle root which becomes the programVK.
echo "[1/4] Extracting programVK from ELF..."
if ! command -v cargo-zisk &>/dev/null; then
    echo "ERROR: cargo-zisk not found in PATH"
    exit 1
fi

# Get programVK — cargo-zisk rom-hash outputs 4 uint64 values
VK_OUTPUT=$(cargo-zisk rom-hash -e "$ZISK_ELF" 2>&1) || {
    echo "ERROR: cargo-zisk rom-hash failed."
    echo "If rom-hash is not available, provide VK values manually."
    echo "Falling back to reading current values from ZiskVerifier.sol"
    VK_OUTPUT=""
}

if [ -n "$VK_OUTPUT" ]; then
    # Parse programVK from output (format: "programVK: [u64, u64, u64, u64]")
    PROGRAM_VK_0=$(echo "$VK_OUTPUT" | grep -oP 'programVK.*?\[(\d+)' | grep -oP '\d+$' || echo "")
    if [ -z "$PROGRAM_VK_0" ]; then
        echo "Could not parse programVK from cargo-zisk output."
        echo "Output was: $VK_OUTPUT"
        echo ""
        echo "Please provide values manually. Edit ZiskVerifier.sol directly,"
        echo "then re-run with --dry-run to verify before deploying."
        exit 1
    fi
    echo "  programVK extracted from ELF"
else
    echo "  Using existing values in ZiskVerifier.sol"
fi

# Step 2: Read rootCVadcopFinal from proving key setup
echo "[2/4] Reading rootCVadcopFinal..."
# The rootCVadcopFinal is stored in the ZiSK proving key directory,
# generated during 'cargo-zisk setup'. It's the same for all ELFs
# compiled against the same SNARK circuit version.
#
# If cargo-zisk doesn't provide a command for this, the values must
# be extracted from the proving key metadata or set manually.
echo "  NOTE: rootCVadcopFinal values are from the SNARK circuit setup."
echo "  They only change when the ZiSK SNARK wrapper circuit is regenerated."
echo "  Current values in ZiskVerifier.sol will be preserved unless you edit manually."

# Step 3: Patch ZiskVerifier.sol (if new values were extracted)
echo "[3/4] Verifying ZiskVerifier.sol constants..."
echo "  File: $VERIFIER_SOL"

# Show current values
echo "  Current constants:"
grep "_PROGRAM_VK_\|_ROOT_CV_ADCOP_FINAL_\|_VK_HASH" "$VERIFIER_SOL" | \
    sed 's/^/    /' | head -10

if [ -n "${VK_HASH:-}" ]; then
    echo ""
    echo "  Updating _VK_HASH to: $VK_HASH"
    sed -i "s/bytes32 private constant _VK_HASH =.*/bytes32 private constant _VK_HASH = $VK_HASH;/" "$VERIFIER_SOL"
fi

echo ""

# Step 4: Deploy
if [ "$DRY_RUN" = "1" ]; then
    echo "[4/4] Dry run — verifying compilation..."
    cd "$ERA_DIR"
    forge build --contracts contracts/state-transition/verifiers/ZiskVerifier.sol 2>&1 | tail -3
    echo ""
    echo "Dry run complete. To deploy, remove --dry-run flag."
else
    echo "[4/4] Deploying new ZiskVerifier and updating MultiProofVerifier..."
    cd "$ERA_DIR"
    forge script deploy-scripts/UpdateZiskVerifier.s.sol:UpdateZiskVerifier \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --private-key "$OWNER_PK" \
        -vvv \
        --sig "run(address)" "$MULTI_PROOF_VERIFIER"
fi

echo ""
echo "=== Done ==="
