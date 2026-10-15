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
  // which routes through the gateway and does not record the L2 upgrade transaction on L1. The runner keeps
  // only the chains that settle on L1 in the source states, the gateway itself included, since chains 12 and
  // 14 settle on the gateway in the v0.34.0 states but on L1 in the current config.
  targetRoles: ["directSettled", "gateway"],
  // Runs on the two target chains: the gateway stands in as an ordinary L1-settled peer, being the only other
  // chain the upgrade covers.
  checkInteropGating: true,
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Latest upgrade test failed:", error.message || error);
    process.exit(1);
  });
