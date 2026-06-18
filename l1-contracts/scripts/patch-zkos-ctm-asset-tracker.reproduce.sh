#!/usr/bin/env bash
#
# Reproduce + verify the ZKsync OS CTM asset-tracker patch proposal (PR #2224):
#   1. build the l1-contracts EVM artifacts with the exact foundry-zksync version
#      used to generate AllContractsHashes.json,
#   2. run the forge patch script — reconstructs the CTM data from scratch out of
#      the real compiled bytecode, generates the ChainTypeManager calls, and
#      writes the dedicated patch proposal TOML,
#   3. run the TypeScript verifier — pulls the ORIGINAL data straight from the
#      CTM's on-chain events and asserts the proposal only swaps the changed
#      bytecode descriptors (per AllContractsHashes.json) and that the calls are
#      correctly constructed.
#
# Run from the l1-contracts directory:
#   ./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh
#
# Requirements:
#   - foundry-zksync v0.1.5 on PATH (install via: foundryup-zksync -i 0.1.5)
#   - L1_RPC (or TENDERLY_SEPOLIA) pointing at the L1 the CTM lives on (Sepolia)
#   - SKIP_BUILD=1 reuses existing artifacts (the build is the slow part)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # The committed AllContractsHashes.json is produced with this exact version
  # (see recompute_hashes.sh). A different toolchain emits different solc
  # metadata, so the deployed-bytecode hashes would not match.
  echo ">>> Building l1-contracts EVM artifacts with foundry-zksync v0.1.5"
  forge --version | head -n 1
  forge build
fi

echo ">>> Regenerating the ZKsync OS genesis (the #2224 genesis-only contracts move the root)"
( cd ../tools/zksync-os-genesis-gen && cargo run --release )
rm -f ../zksync-os-genesis.json   # drop the tool's duplicate dump; latest.json is the artifact

echo ">>> Running forge patch script (reconstruct from bytecode + generate calls)"
forge script deploy-scripts/upgrade/v31/PatchZkosCtmAssetTracker.s.sol --ffi --sig "run()"

echo ">>> Verifying the proposal against on-chain CTM events (hashes-only)"
npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts
