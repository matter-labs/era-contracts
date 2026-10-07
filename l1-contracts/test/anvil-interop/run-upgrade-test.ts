#!/usr/bin/env node

import { readStateVersion } from "./src/core/anvil-config";
import { runUpgradeScenario } from "./src/helpers/upgrade-test-runner";

// The upgrade the current release ships, exactly as protocol-ops prepares it by default, applied to the previous
// release's ecosystem (`upgradeSourceStateVersion` in config/anvil-config.json). The target version is the one
// in the ZKsync OS genesis config, so nothing here names a release.
runUpgradeScenario({
  label: "latest-upgrade",
  stateVersion: readStateVersion("upgradeSourceStateVersion"),
  // The fixture's chains still carry the genesis-upgrade tx hash from their creation, which blocks a new
  // upgrade (`PreviousUpgradeNotFinalized`).
  clearGenesisUpgradeTxHash: true,
  // Gateway-settled chains are not covered: their upgrade takes the `s.settlementLayer != address(0)` path,
  // which routes through the gateway and does not record the L2 upgrade transaction on L1. Chain 10
  // (L1-settled) and 11 (the gateway itself, which settles on L1) are the shapes upgraded from L1.
  targetRoles: ["directSettled", "gateway"],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Latest upgrade test failed:", error.message || error);
    process.exit(1);
  });
