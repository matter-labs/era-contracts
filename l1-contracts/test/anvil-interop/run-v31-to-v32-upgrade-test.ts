#!/usr/bin/env node

import { runV31UpgradeScenario } from "./src/helpers/v31-upgrade-test-runner";

// The upgrade this release actually performs: a v31 ecosystem (ZKsync OS chains, one of them a gateway)
// onto the current contracts. Replaces the former v29 -> v31 scenario, which this release no longer
// supports: the contracts introduced in v31 are initialized on the genesis path only now.
runV31UpgradeScenario({
  label: "v31-zksync-os",
  stateVersion: "v0.31.0",
  permanentValuesTemplatePath: "test/anvil-interop/config/v31-permanent-values.toml",
  upgradeInputTemplatePath: "test/anvil-interop/config/v31-to-v32-upgrade.toml",
  isZKsyncOS: true,
  expectedProtocolVersion: "0x2000000000",
  // The fixture leaves the ChainAssetHandler with the deployer as owner; governance has to own it to run
  // the stage-0 `pauseMigration()` call.
  transferL1ChainAssetHandlerOwnership: true,
  // The fixture's chains still carry the genesis-upgrade tx hash from their creation, which blocks a new
  // upgrade (`PreviousUpgradeNotFinalized`), and their batch counters are zero. Same test-only bridge the
  // pre-v31 scenarios used.
  clearGenesisUpgradeTxHash: true,
  seedBatchCounters: true,
  // Chains 12 and 13 are excluded: the v31 state generation left their L2 side uninitialized (the asset
  // tracker has code but no storage), so they cannot be upgraded from that fixture. Chain 10
  // (L1-settled), 11 (the gateway) and 14 (settled on the gateway) do carry initialized L2 state.
  targetRoles: ["directSettled", "gateway"],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("V31 -> V32 upgrade test failed:", error.message || error);
    process.exit(1);
  });
