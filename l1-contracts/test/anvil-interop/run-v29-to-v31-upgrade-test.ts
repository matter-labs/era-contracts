#!/usr/bin/env node

import { runV31UpgradeScenario } from "./src/helpers/v31-upgrade-test-runner";

runV31UpgradeScenario({
  label: "v29-era",
  stateVersion: "v0.29.0",
  permanentValuesTemplatePath: "test/anvil-interop/config/v29-permanent-values.toml",
  upgradeInputTemplatePath: "test/anvil-interop/config/v29-to-v31-upgrade.toml",
  isZKsyncOS: false,
}).catch((error) => {
  console.error("V29 Era -> V31 upgrade test failed:", error.message || error);
  process.exit(1);
});
