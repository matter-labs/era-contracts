#!/usr/bin/env node

import { runPipelineUpgradeScenario } from "./src/helpers/pipeline-upgrade-runner";

// The v34 BOOTSTRAP edge followed by the first REGISTRY-DRIVEN upgrade, both driven end to end
// by the production toolchain. Bootstrap: protocol-ops
// `upgrade-prepare-all` runs the real `CTMUpgrade_v34` / `CoreUpgrade_v34` prepare (deploying
// the `CTMUpgradeExecutor` + `RegistryBootstrapMigration`), and the governance replay executes
// the collapsed stage-1 leg — nominate the CTM, hand over its ProxyAdmin, `migrate()`,
// `acceptCTMOwnership()`. Chains cross via the legacy handed-cut entrypoint, the production
// shape for pre-v34 chains. See docs/registry-driven-upgrades.md (Bootstrap).
runPipelineUpgradeScenario({
  label: "v34-bootstrap",
  // The FROZEN departing-version fixture (see chain-states/README.md). Its chains live at
  // protocol version 0x2000000000 — the version metadata lags its source era; the frozen
  // snapshot is what production departs from either way.
  stateVersion: "v0.33.0",
  permanentValuesTemplatePath: "test/anvil-interop/config/bootstrap-permanent-values.toml",
  upgradeInputTemplatePath: "test/anvil-interop/config/bootstrap-upgrade.toml",
  isZKsyncOS: true,
  expectedProtocolVersion: "0x2200000000",
  coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests.sol:CoreUpgradeForTests",
  ctmScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests.sol:CTMUpgradeForTests",
  // The proposed upgrade's L2 leg delegates to `L2V34Upgrade` (the upgrade-time re-init, force
  // deployed at a derived address); the anvil L2s cannot force-deploy, so the harness places
  // this bytecode at the decoded delegate target.
  l2DelegateBytecodeName: "L2V34Upgrade",
  // The fixture leaves the ChainAssetHandler with the deployer as owner; governance has to own
  // it to run the stage-0 `pauseMigration()` call.
  transferL1ChainAssetHandlerOwnership: true,
  // The fixture's chains still carry the genesis-upgrade tx hash from their creation, which
  // blocks a new upgrade (`PreviousUpgradeNotFinalized`).
  clearGenesisUpgradeTxHash: true,
  // The frozen fixture's chains carry the REAL pre-v34 cut-taking Admin facet, so they cross
  // the edge natively — no shim.
  installLegacyCutTakingFacet: false,
  // gwSettled chains are not covered: their upgrade routes through the gateway CTM, which the
  // registry model cannot bump yet (no EraVM-deployable release). Chain 10 (L1-settled) and 11
  // (the gateway itself, which settles on L1) are the supported shapes.
  targetRoles: ["directSettled", "gateway"],
  // Then the FIRST registry-driven upgrade on the bootstrapped ecosystem ("v34 -> v35"), driven
  // by the base prepare pipeline: one fresh ecosystem implementation pinned in a CoreRegistry, a
  // fresh release pinned by a CTMTransition, and exactly three governance calls.
  followUp: {
    label: "v35-registry-driven",
    upgradeInputTemplatePath: "test/anvil-interop/config/recurring-upgrade.toml",
    expectedProtocolVersion: "0x2300000000",
    coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v35.sol:CoreUpgradeForTests_v35",
    ctmScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v35.sol:CTMUpgradeForTests_v35",
  },
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Bootstrap upgrade test failed:", error.message || error);
    process.exit(1);
  });
