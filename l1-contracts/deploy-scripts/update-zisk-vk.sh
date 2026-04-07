#!/usr/bin/env bash
# Update ZiSK verification keys and redeploy the ZiskVerifier contract.
#
# Fully automated: extracts programVK from `cargo-zisk rom-setup` output
# and rootCVadcopFinal from the SNARK proving key, patches ZiskVerifier.sol,
# computes VK hash, deploys, and activates.
#
# Prerequisites:
#   - cargo-zisk in PATH (ZiSK toolchain)
#   - forge in PATH (Foundry)
#   - ZiSK guest ELF compiled
#   - ZiSK proving key directory (~/.zisk/provingKey)
#   - ZiSK SNARK proving key directory (~/.zisk/provingKeySnark)
#
# Usage:
#   ./update-zisk-vk.sh \
#     --elf /path/to/zksync-os-zisk-guest \
#     --rpc-url http://localhost:8545 \
#     --verifier 0x<MultiProofVerifier> \
#     --private-key 0x<owner_pk>
#
#   Add --dry-run to only patch + compile without deploying.
#   Add --extract-only to just print the new constants.

set -euo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.zisk/bin:$HOME/.foundry/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERA_DIR="$(dirname "$SCRIPT_DIR")"
VERIFIER_SOL="$ERA_DIR/contracts/state-transition/verifiers/ZiskVerifier.sol"

# Defaults
PROVING_KEY="${PROVING_KEY:-$HOME/.zisk/provingKey}"
PROVING_KEY_SNARK="${PROVING_KEY_SNARK:-$HOME/.zisk/provingKeySnark}"
DRY_RUN=0
EXTRACT_ONLY=0

# Parse args
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
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

: "${ZISK_ELF:?--elf required (path to ZiSK guest ELF binary)}"

echo "=== ZiSK Verification Key Update ==="
echo ""

# ── Step 1: Extract programVK via rom-setup ───────────────────────────
echo "[1/5] Extracting programVK from guest ELF..."
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

cargo-zisk rom-setup -e "$ZISK_ELF" -k "$PROVING_KEY" -o "$WORK_DIR" -v 2>&1 | \
    grep -v "^$" | tail -5

# programVK = ROM hash, extracted from the output filename
ROM_HASH=$(ls "$WORK_DIR"/*.verkey.bin 2>/dev/null | head -1 | xargs basename | cut -d_ -f1)
if [ -z "$ROM_HASH" ] || [ ${#ROM_HASH} -ne 64 ]; then
    echo "ERROR: Could not extract ROM hash from rom-setup output"
    echo "Files in work dir:"; ls "$WORK_DIR/"
    exit 1
fi

# Convert 32-byte hex to 4 little-endian uint64
read -r PVK0 PVK1 PVK2 PVK3 < <(python3 -c "
import struct
h = bytes.fromhex('$ROM_HASH')
vals = struct.unpack('<4Q', h)
print(' '.join(str(v) for v in vals))
")

echo "  ROM hash:    $ROM_HASH"
echo "  programVK:   [$PVK0, $PVK1, $PVK2, $PVK3]"

# ── Step 2: Read rootCVadcopFinal from SNARK proving key ─────────────
echo ""
echo "[2/5] Reading rootCVadcopFinal from SNARK setup..."
VERKEY_JSON="$PROVING_KEY_SNARK/vadcop_final.verkey.json"
if [ ! -f "$VERKEY_JSON" ]; then
    echo "ERROR: $VERKEY_JSON not found"
    echo "Run 'cargo-zisk setup' first to generate SNARK proving keys"
    exit 1
fi

read -r RCV0 RCV1 RCV2 RCV3 < <(python3 -c "
import json
with open('$VERKEY_JSON') as f:
    vals = json.load(f)
print(' '.join(str(v) for v in vals))
")

echo "  rootCVadcopFinal: [$RCV0, $RCV1, $RCV2, $RCV3]"

# ── Step 3: Compute VK hash ──────────────────────────────────────────
echo ""
echo "[3/5] Computing VK hash..."
# VK hash = keccak256(abi.encodePacked(programVK, rootCVadcopFinal))
# This must match the server's ProvingVersion VK hash for proof routing.
VK_HASH=$(python3 -c "
import struct, hashlib
from Crypto.Hash import keccak  # pycryptodome

pvk = struct.pack('<4Q', $PVK0, $PVK1, $PVK2, $PVK3)
rcv = struct.pack('<4Q', $RCV0, $RCV1, $RCV2, $RCV3)
k = keccak.new(digest_bits=256)
k.update(pvk + rcv)
print('0x' + k.hexdigest())
" 2>/dev/null || python3 -c "
# Fallback without pycryptodome — use pysha3 or web3
import struct
pvk = struct.pack('<4Q', $PVK0, $PVK1, $PVK2, $PVK3)
rcv = struct.pack('<4Q', $RCV0, $RCV1, $RCV2, $RCV3)
try:
    import sha3
    h = sha3.keccak_256(pvk + rcv).hexdigest()
except ImportError:
    # Last resort: use cast
    import subprocess
    data_hex = (pvk + rcv).hex()
    result = subprocess.run(['cast', 'keccak', '0x' + data_hex], capture_output=True, text=True)
    h = result.stdout.strip().replace('0x', '')
print('0x' + h)
")

echo "  VK hash: $VK_HASH"

if [ "$EXTRACT_ONLY" = "1" ]; then
    echo ""
    echo "=== Extracted Constants ==="
    echo "  _PROGRAM_VK_0 = $PVK0"
    echo "  _PROGRAM_VK_1 = $PVK1"
    echo "  _PROGRAM_VK_2 = $PVK2"
    echo "  _PROGRAM_VK_3 = $PVK3"
    echo "  _ROOT_CV_ADCOP_FINAL_0 = $RCV0"
    echo "  _ROOT_CV_ADCOP_FINAL_1 = $RCV1"
    echo "  _ROOT_CV_ADCOP_FINAL_2 = $RCV2"
    echo "  _ROOT_CV_ADCOP_FINAL_3 = $RCV3"
    echo "  _VK_HASH = $VK_HASH"
    exit 0
fi

# ── Step 4: Patch ZiskVerifier.sol ────────────────────────────────────
echo ""
echo "[4/5] Patching ZiskVerifier.sol..."

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

echo "  Patched $VERIFIER_SOL"
echo "  New constants:"
grep "_PROGRAM_VK_\|_ROOT_CV_ADCOP_FINAL_\|_VK_HASH" "$VERIFIER_SOL" | sed 's/^/    /'

# Verify compilation
cd "$ERA_DIR"
forge build --contracts contracts/state-transition/verifiers/ZiskVerifier.sol 2>&1 | tail -3

# ── Step 5: Deploy ────────────────────────────────────────────────────
echo ""
if [ "$DRY_RUN" = "1" ]; then
    echo "[5/5] Dry run complete. Review the patched contract, then deploy with:"
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
