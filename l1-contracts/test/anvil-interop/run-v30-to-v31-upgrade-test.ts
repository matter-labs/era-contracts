#!/usr/bin/env node

import { runV31UpgradeScenario } from "./src/helpers/v31-upgrade-test-runner";

runV31UpgradeScenario({
  label: "v30-zksync-os",
  stateVersion: "v0.30.0",
  permanentValuesTemplatePath: "upgrade-envs/permanent-values/local.toml",
  upgradeInputTemplatePath: "upgrade-envs/v0.30.0-zksync-os-blobs/localhost.toml",
  isZKsyncOS: true,
  targetRoles: ["gateway", "gwSettled"],
  clearGenesisUpgradeTxHash: true,
  seedBatchCounters: true,
  transferL1AssetTrackerOwnership: true,
}).catch((error) => {
  console.error("V30 ZKsync OS -> V31 upgrade test failed:", error.message || error);
  process.exit(1);
});
