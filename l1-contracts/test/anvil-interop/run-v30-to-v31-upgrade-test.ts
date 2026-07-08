#!/usr/bin/env node

import { runV31UpgradeScenario } from "./src/helpers/v31-upgrade-test-runner";

runV31UpgradeScenario({
  label: "v30-zksync-os",
  stateVersion: "v0.30.0",
  permanentValuesTemplatePath: "test/anvil-interop/config/v30-permanent-values.toml",
  upgradeInputTemplatePath: "upgrade-envs/v0.30.0-zksync-os-blobs/localhost.toml",
  isZKsyncOS: true,
  targetRoles: ["gateway", "gwSettled"],
  clearGenesisUpgradeTxHash: true,
  seedBatchCounters: true,
  // In v30 chain states, the recorded address is the old L1ChainAssetHandler proxy.
  // Governance needs ownership to call pauseMigration() in stage 0.
  transferL1ChainAssetHandlerOwnership: true,
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("V30 ZKsync OS -> V31 upgrade test failed:", error.message || error);
    process.exit(1);
  });
