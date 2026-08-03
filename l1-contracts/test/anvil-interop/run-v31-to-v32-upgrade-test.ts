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
  targetRoles: ["directSettled", "gateway", "gwSettled"],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("V31 -> V32 upgrade test failed:", error.message || error);
    process.exit(1);
  });
