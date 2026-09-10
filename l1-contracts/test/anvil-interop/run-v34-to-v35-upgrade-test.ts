#!/usr/bin/env node

import { runRegistryDrivenUpgradeScenario } from "./src/helpers/registry-upgrade-test-runner";

runRegistryDrivenUpgradeScenario({
  label: "registry-v35",
  stateVersion: "v0.34.0",
  // Only chains that settle on L1 take the full upgrade (CTM bump + diamond cut + committed
  // L2 upgrade tx). directSettled = chain 10, gateway = the gateway chain itself (chain 11).
  targetRoles: ["directSettled", "gateway"],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Registry-driven upgrade test failed:", error.message || error);
    process.exit(1);
  });
