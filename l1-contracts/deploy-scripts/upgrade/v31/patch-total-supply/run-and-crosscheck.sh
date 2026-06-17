#!/usr/bin/env bash
#
# Runs the TypeScript byte-replacement double-check for the v31 totalSupply-fix upgrade-data
# patch. It reads the previous upgrade cut ON CHAIN from the Era ChainTypeManager and recomputes
# the corrected upgrade-cut hash. If the Solidity prep output
# (patched-execute-upgrade-calls.json) is present it asserts the two agree.
#
# The MAIN script (PatchTotalSupplyV31.runPatch) regenerates + publishes the upgrade data via the
# real CTMUpgrade_v31 machinery and must be run in the v31 upgrade/deployer environment — see
# README.md. This double-check only needs the RPC env var named in config.json.
#
# Run from the l1-contracts directory.
set -euo pipefail
cd "$(dirname "$0")/../../../.."   # -> l1-contracts
npx ts-node scripts/patch-total-supply-crosscheck.ts
