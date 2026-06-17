#!/usr/bin/env bash
#
# Reproduce the ZKsync OS CTM asset-tracker upgrade patch (PR #2224) end-to-end:
#   1. build the l1-contracts EVM artifacts with the exact foundry-zksync version
#      used to generate AllContractsHashes.json,
#   2. run the forge patch script (bytecode-based),
#   3. run the TypeScript verifier (hashes-only),
#   4. assert that both produce byte-identical ZKsync OS CTM data.
#
# Run from the l1-contracts directory:
#   ./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh
#
# The build step is the slow part; set SKIP_BUILD=1 to reuse existing artifacts.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_OUT="script-out/zkos-ctm-asset-tracker-patch.forge.json"
TS_OUT="script-out/zkos-ctm-asset-tracker-patch.ts.json"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # The committed AllContractsHashes.json is produced with this exact version
  # (see recompute_hashes.sh). A different toolchain emits different solc
  # metadata, so the deployed-bytecode hashes would not match.
  echo ">>> Building l1-contracts EVM artifacts with foundry-zksync v0.1.5"
  echo "    (install via: foundryup-zksync -i 0.1.5)"
  forge --version | head -n 1
  forge build
fi

echo ">>> Running forge patch script (bytecode-based)"
forge script deploy-scripts/upgrade/v31/PatchZkosCtmAssetTracker.s.sol --ffi --sig "run()"

echo ">>> Running TypeScript verifier (hashes-only)"
npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts

echo ">>> Comparing the two outputs"
node -e '
const fs = require("fs");
const f = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const t = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const eq = (a, b) => (a || "").toLowerCase() === (b || "").toLowerCase();
const checks = {
  forceDeploymentsData: eq(f.forceDeploymentsData, t.forceDeploymentsData),
  chainUpgradeDiamondCut: eq(f.chainUpgradeDiamondCut, t.chainUpgradeDiamondCut),
  diamondCutDataUnchanged: eq(f.diamondCutDataUnchanged, t.diamondCutDataUnchanged),
  v31DelegateNew: eq(f.v31DelegateNew, t.v31DelegateNew),
};
for (const [k, v] of Object.entries(checks)) console.log(`  ${v ? "OK" : "MISMATCH"}  ${k}`);
if (!Object.values(checks).every(Boolean)) {
  console.error("FORGE and TS outputs differ!");
  process.exit(1);
}
console.log("\nforge (bytecode-based) and TypeScript (hashes-only) outputs MATCH.");
' "$FORGE_OUT" "$TS_OUT"
