#!/usr/bin/env bash
#
# Reproduce the ZKsync OS CTM asset-tracker upgrade patch (PR #2224) end-to-end:
#   1. build the l1-contracts EVM artifacts with the exact foundry-zksync version
#      used to generate AllContractsHashes.json,
#   2. run the forge patch script (bytecode-based, reconstructs from scratch +
#      generates the ChainTypeManager calls; writes the dedicated patch TOML),
#   3. run the TypeScript verifier (hashes-only, byte-patches + re-derives the
#      same calls),
#   4. assert that both produce byte-identical ZKsync OS CTM data AND calls.
#
# Run from the l1-contracts directory:
#   ./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh
#
# The build step is the slow part; set SKIP_BUILD=1 to reuse existing artifacts.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_OUT="upgrade-envs/v0.31.0-interopB/output/stage/zkos-asset-tracker-patch.toml"
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

echo ">>> Running forge patch script (bytecode-based, reconstruct + calls)"
forge script deploy-scripts/upgrade/v31/PatchZkosCtmAssetTracker.s.sol --ffi --sig "run()"

echo ">>> Running TypeScript verifier (hashes-only + calls)"
npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts

echo ">>> Comparing the two outputs (data + ChainTypeManager calls)"
node -e '
const fs = require("fs");
const toml = require("toml");
const f = toml.parse(fs.readFileSync(process.argv[1], "utf8")).zksync_os;
const t = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const eq = (a, b) => String(a || "").toLowerCase() === String(b || "").toLowerCase();
const checks = {
  force_deployments_data: eq(f.force_deployments_data, t.forceDeploymentsData),
  chain_upgrade_diamond_cut: eq(f.chain_upgrade_diamond_cut, t.chainUpgradeDiamondCut),
  diamond_cut_data: eq(f.diamond_cut_data, t.diamondCutData),
  chain_creation_params: eq(f.chain_creation_params, t.chainCreationParams),
  set_chain_creation_params_calldata: eq(f.set_chain_creation_params_calldata, t.setChainCreationParamsCalldata),
  set_upgrade_diamond_cut_calldata: eq(f.set_upgrade_diamond_cut_calldata, t.setUpgradeDiamondCutCalldata),
  governance_calls: eq(f.governance_calls, t.governanceCalls),
  old_protocol_version: eq(f.old_protocol_version, t.oldProtocolVersion),
};
for (const [k, v] of Object.entries(checks)) console.log(`  ${v ? "OK" : "MISMATCH"}  ${k}`);
if (!Object.values(checks).every(Boolean)) {
  console.error("FORGE and TS outputs differ!");
  process.exit(1);
}
console.log("\nforge (bytecode-based) and TypeScript (hashes-only) outputs MATCH (data + calls).");
' "$FORGE_OUT" "$TS_OUT"
