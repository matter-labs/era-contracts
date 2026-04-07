#!/usr/bin/env bash
# Update ZiSK verification keys and redeploy the ZiskVerifier contract.
#
# ZiSK generates Solidity verifier contracts during SNARK key setup:
#   ~/.zisk/provingKeySnark/final/PlonkVerifier.sol  (inner SNARK verifier)
#   ~/.zisk/provingKeySnark/final/ZiskVerifier.sol   (wrapper with rootCVadcopFinal)
#
# The programVK (ROM Merkle root) changes per guest ELF build and is extracted
# via `cargo-zisk rom-setup`. The PlonkVerifier/rootCVadcopFinal change only
# when the SNARK circuit is regenerated (`ziskup setup_snark`).
#
# This script:
# 1. Extracts programVK from the guest ELF via `cargo-zisk rom-setup`
# 2. Reads rootCVadcopFinal from the ZiSK SNARK setup output
# 3. Patches ZiskVerifier.sol (era-contracts version) with new constants
# 4. Optionally copies PlonkVerifier.sol if SNARK circuit changed
# 5. Deploys and activates via MultiProofVerifier.setZiskVerifier()
#
# NOTE: ZiSK generates its own Solidity verifiers at:
#   ~/.zisk/provingKeySnark/final/{PlonkVerifier,ZiskVerifier,IZiskVerifier}.sol
# The era-contracts versions are adapted from these (different interface to
# match IVerifier, hardcoded programVK for L1 Executor protocol).
#
# Usage:
#   # Extract and print new constants:
#   ./update-zisk-vk.sh --elf /path/to/guest --extract-only
#
#   # Patch + compile (no deploy):
#   ./update-zisk-vk.sh --elf /path/to/guest --dry-run
#
#   # Full deploy:
#   ./update-zisk-vk.sh --elf /path/to/guest \
#     --rpc-url http://localhost:8545 \
#     --verifier 0x<MultiProofVerifier> \
#     --private-key 0x<owner>
#
#   # Also update PlonkVerifier (after `ziskup setup_snark`):
#   ./update-zisk-vk.sh --elf /path/to/guest --update-plonk --dry-run

set -euo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.zisk/bin:$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERA_DIR="$(dirname "$SCRIPT_DIR")"
VERIFIER_SOL="$ERA_DIR/contracts/state-transition/verifiers/ZiskVerifier.sol"
PLONK_SOL="$ERA_DIR/contracts/state-transition/verifiers/ZiskSnarkPlonkVerifier.sol"

# Defaults
PROVING_KEY="${PROVING_KEY:-$HOME/.zisk/provingKey}"
PROVING_KEY_SNARK="${PROVING_KEY_SNARK:-$HOME/.zisk/provingKeySnark}"
DRY_RUN=0
EXTRACT_ONLY=0
UPDATE_PLONK=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --elf) ZISK_ELF="$2"; shift 2 ;;
        --rpc-url) RPC_URL="$2"; shift 2 ;;
        --verifier) MULTI_PROOF_VERIFIER="$2"; shift 2 ;;
        --private-key) OWNER_PK="$2"; shift 2 ;;
        --proving-key) PROVING_KEY="$2"; shift 2 ;;
        --proving-key-snark) PROVING_KEY_SNARK="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --extract-only) EXTRACT_ONLY=1; shift ;;
        --update-plonk) UPDATE_PLONK=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

: "${ZISK_ELF:?--elf required (path to ZiSK guest ELF binary)}"

echo "=== ZiSK Verification Key Update ==="
echo ""

# ── Step 1: Extract programVK ─────────────────────────────────────────
echo "[1/5] Extracting programVK from guest ELF via cargo-zisk rom-setup..."
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

cargo-zisk rom-setup -e "$ZISK_ELF" -k "$PROVING_KEY" -o "$WORK_DIR" -v 2>&1 | tail -3

ROM_HASH=$(ls "$WORK_DIR"/*.verkey.bin 2>/dev/null | head -1 | xargs basename | cut -d_ -f1)
if [ -z "$ROM_HASH" ] || [ ${#ROM_HASH} -ne 64 ]; then
    echo "ERROR: Could not extract ROM hash from rom-setup output"
    ls "$WORK_DIR/"
    exit 1
fi

read -r PVK0 PVK1 PVK2 PVK3 < <(python3 -c "
import struct
h = bytes.fromhex('$ROM_HASH')
vals = struct.unpack('<4Q', h)
print(' '.join(str(v) for v in vals))
")

echo "  ROM hash:  $ROM_HASH"
echo "  programVK: [$PVK0, $PVK1, $PVK2, $PVK3]"

# ── Step 2: Read rootCVadcopFinal ─────────────────────────────────────
echo ""
echo "[2/5] Reading rootCVadcopFinal from ZiSK SNARK setup..."

# ZiSK generates this at setup time:
VERKEY_JSON="$PROVING_KEY_SNARK/vadcop_final.verkey.json"
if [ ! -f "$VERKEY_JSON" ]; then
    echo "ERROR: $VERKEY_JSON not found. Run: ziskup setup_snark"
    exit 1
fi

read -r RCV0 RCV1 RCV2 RCV3 < <(python3 -c "
import json
with open('$VERKEY_JSON') as f:
    vals = json.load(f)
print(' '.join(str(v) for v in vals))
")

echo "  rootCVadcopFinal: [$RCV0, $RCV1, $RCV2, $RCV3]"

# Cross-check with the generated ZiskVerifier.sol
GENERATED_ZV="$PROVING_KEY_SNARK/final/ZiskVerifier.sol"
if [ -f "$GENERATED_ZV" ]; then
    echo "  ZiSK-generated contracts found at: $PROVING_KEY_SNARK/final/"
    echo "  (PlonkVerifier.sol, ZiskVerifier.sol, IZiskVerifier.sol)"
fi

# ── Step 3: Compute VK hash ──────────────────────────────────────────
echo ""
echo "[3/5] Computing VK hash..."
VK_HASH=$(python3 -c "
import struct, subprocess
pvk = struct.pack('<4Q', $PVK0, $PVK1, $PVK2, $PVK3)
rcv = struct.pack('<4Q', $RCV0, $RCV1, $RCV2, $RCV3)
data_hex = (pvk + rcv).hex()
result = subprocess.run(['cast', 'keccak', '0x' + data_hex], capture_output=True, text=True)
print(result.stdout.strip())
")
echo "  VK hash: $VK_HASH"

if [ "$EXTRACT_ONLY" = "1" ]; then
    echo ""
    echo "=== Constants for ZiskVerifier.sol ==="
    echo "  uint64 private constant _PROGRAM_VK_0 = $PVK0;"
    echo "  uint64 private constant _PROGRAM_VK_1 = $PVK1;"
    echo "  uint64 private constant _PROGRAM_VK_2 = $PVK2;"
    echo "  uint64 private constant _PROGRAM_VK_3 = $PVK3;"
    echo ""
    echo "  uint64 private constant _ROOT_CV_ADCOP_FINAL_0 = $RCV0;"
    echo "  uint64 private constant _ROOT_CV_ADCOP_FINAL_1 = $RCV1;"
    echo "  uint64 private constant _ROOT_CV_ADCOP_FINAL_2 = $RCV2;"
    echo "  uint64 private constant _ROOT_CV_ADCOP_FINAL_3 = $RCV3;"
    echo ""
    echo "  bytes32 private constant _VK_HASH = $VK_HASH;"
    echo ""
    echo "ZiSK-generated Solidity verifiers (for reference):"
    echo "  $PROVING_KEY_SNARK/final/PlonkVerifier.sol"
    echo "  $PROVING_KEY_SNARK/final/ZiskVerifier.sol"
    echo "  $PROVING_KEY_SNARK/final/IZiskVerifier.sol"
    exit 0
fi

# ── Step 4: Patch contracts ───────────────────────────────────────────
echo ""
echo "[4/5] Patching era-contracts..."

# Patch programVK constants
sed -i "s/uint64 private constant _PROGRAM_VK_0 = [0-9]*/uint64 private constant _PROGRAM_VK_0 = $PVK0/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _PROGRAM_VK_1 = [0-9]*/uint64 private constant _PROGRAM_VK_1 = $PVK1/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _PROGRAM_VK_2 = [0-9]*/uint64 private constant _PROGRAM_VK_2 = $PVK2/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _PROGRAM_VK_3 = [0-9]*/uint64 private constant _PROGRAM_VK_3 = $PVK3/" "$VERIFIER_SOL"

# Patch rootCVadcopFinal constants
sed -i "s/uint64 private constant _ROOT_CV_ADCOP_FINAL_0 = [0-9]*/uint64 private constant _ROOT_CV_ADCOP_FINAL_0 = $RCV0/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _ROOT_CV_ADCOP_FINAL_1 = [0-9]*/uint64 private constant _ROOT_CV_ADCOP_FINAL_1 = $RCV1/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _ROOT_CV_ADCOP_FINAL_2 = [0-9]*/uint64 private constant _ROOT_CV_ADCOP_FINAL_2 = $RCV2/" "$VERIFIER_SOL"
sed -i "s/uint64 private constant _ROOT_CV_ADCOP_FINAL_3 = [0-9]*/uint64 private constant _ROOT_CV_ADCOP_FINAL_3 = $RCV3/" "$VERIFIER_SOL"

# Patch VK hash
sed -i "s|bytes32 private constant _VK_HASH =.*|bytes32 private constant _VK_HASH = $VK_HASH;|" "$VERIFIER_SOL"

echo "  Patched: $VERIFIER_SOL"

# Optionally update PlonkVerifier from ZiSK-generated version
if [ "$UPDATE_PLONK" = "1" ]; then
    GENERATED_PLONK="$PROVING_KEY_SNARK/final/PlonkVerifier.sol"
    if [ ! -f "$GENERATED_PLONK" ]; then
        echo "ERROR: $GENERATED_PLONK not found. Run: ziskup setup_snark"
        exit 1
    fi
    # Copy the generated PlonkVerifier, adjusting pragma and contract name
    # for era-contracts conventions
    sed -e 's/pragma solidity >=0.7.0 <0.9.0;/pragma solidity 0.8.28;/' \
        -e 's/contract PlonkVerifier/contract ZiskSnarkPlonkVerifier/' \
        "$GENERATED_PLONK" > "$PLONK_SOL"
    echo "  Updated: $PLONK_SOL (from ZiSK-generated PlonkVerifier.sol)"
fi

# Verify compilation
cd "$ERA_DIR"
forge build --contracts contracts/state-transition/verifiers/ZiskVerifier.sol 2>&1 | tail -3
echo "  Compilation OK"

# ── Step 5: Deploy ────────────────────────────────────────────────────
echo ""
if [ "$DRY_RUN" = "1" ]; then
    echo "[5/5] Dry run complete. To deploy:"
    echo "  forge script deploy-scripts/UpdateZiskVerifier.s.sol:UpdateZiskVerifier \\"
    echo "    --rpc-url \$RPC_URL --broadcast --private-key \$OWNER_PK \\"
    echo "    --sig 'run(address)' \$MULTI_PROOF_VERIFIER"
else
    : "${RPC_URL:?--rpc-url required for deployment}"
    : "${MULTI_PROOF_VERIFIER:?--verifier required (MultiProofVerifier address)}"
    : "${OWNER_PK:?--private-key required (MultiProofVerifier owner)}"

    echo "[5/5] Deploying new ZiskVerifier..."
    forge script deploy-scripts/UpdateZiskVerifier.s.sol:UpdateZiskVerifier \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --private-key "$OWNER_PK" \
        -vvv \
        --sig "run(address)" "$MULTI_PROOF_VERIFIER"
fi

echo ""
echo "=== Done ==="
