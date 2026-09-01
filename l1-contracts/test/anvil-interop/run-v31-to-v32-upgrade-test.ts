#!/usr/bin/env node

import { runV31UpgradeScenario, TARGET_PROTOCOL_VERSION } from "./src/helpers/v31-upgrade-test-runner";

// The upgrade this release actually performs: a v31 ecosystem (ZKsync OS chains, one of them a gateway)
// onto the current contracts. Replaces the former v29 -> v31 scenario, which this release no longer
// supports: the contracts introduced in v31 are initialized on the genesis path only now.
runV31UpgradeScenario({
  label: "v31-zksync-os",
  stateVersion: "v0.31.0",
  permanentValuesTemplatePath: "test/anvil-interop/config/v31-permanent-values.toml",
  upgradeInputTemplatePath: "test/anvil-interop/config/v31-to-v32-upgrade.toml",
  expectedProtocolVersion: TARGET_PROTOCOL_VERSION,
  // The fixture leaves the ChainAssetHandler with the deployer as owner; governance has to own it to run
  // the stage-0 `pauseMigration()` call.
  transferL1ChainAssetHandlerOwnership: true,
  // The fixture's chains still carry the genesis-upgrade tx hash from their creation, which blocks a new
  // upgrade (`PreviousUpgradeNotFinalized`). Same test-only bridge the pre-v31 scenarios used.
  clearGenesisUpgradeTxHash: true,
  // This release does not support upgrading gateway-settled chains, so no `gwSettled` chain is covered
  // here: their upgrade takes the `s.settlementLayer != address(0)` path, which routes through the gateway
  // and does not record the L2 upgrade transaction on L1. Chain 10 (L1-settled) and 11 (the gateway itself,
  // which settles on L1) are the supported shapes; 12, 13 and 14 are all `gwSettled`. 12 and 13 would be
  // unusable anyway — the v31 state generation left their L2 side uninitialized.
  targetRoles: ["directSettled", "gateway"],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("V31 -> V32 upgrade test failed:", error.message || error);
    process.exit(1);
  });
