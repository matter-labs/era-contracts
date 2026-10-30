#!/usr/bin/env node

import { readStateVersion, readUpgradeSourceGenesisRoot } from "./src/core/anvil-config";
import { runPipelineUpgradeScenario } from "./src/helpers/pipeline-upgrade-runner";
import { packProtocolVersion, readGenesisSemVer } from "./src/helpers/upgrade-test-utils";

// The upgrade the current release ships, exactly as protocol-ops prepares it by default (no script paths: the
// current release's scripts), applied to the previous release's ecosystem (`upgradeSourceStateVersion` in
// config/anvil-config.json). On this release that is the BOOTSTRAP edge into registry-driven upgrades: the
// prepare deploys the `CTMUpgradeExecutor` + `RegistryBootstrapMigration`, the governance replay executes the
// bootstrap's one bundle (`migrate()`, then the completion check), and the chains cross via the legacy handed-cut
// entrypoint, the production shape for pre-registry chains. See docs/registry-driven-upgrades.md (Bootstrap).
// The target version is the one in the ZKsync OS genesis config.
const genesis = readGenesisSemVer();

runPipelineUpgradeScenario({
  label: "bootstrap",
  // The FROZEN previous-release fixture (see chain-states/README.md).
  stateVersion: readStateVersion("upgradeSourceStateVersion"),
  permanentValuesTemplatePath: "test/anvil-interop/config/v35-permanent-values.toml",
  upgradeInputTemplatePath: "test/anvil-interop/config/v35-upgrade.toml",
  isZKsyncOS: true,
  expectedProtocolVersion: packProtocolVersion(genesis),
  // The proposed upgrade's L2 leg delegates to `L2DefaultUpgrade` (the upgrade-time re-init, force
  // deployed at a derived address); the anvil L2s cannot force-deploy, so the harness places
  // this bytecode at the decoded delegate target.
  l2DelegateBytecodeName: "L2DefaultUpgrade",
  sourceGenesis: { genesisBatchHash: readUpgradeSourceGenesisRoot(), genesisIndexRepeatedStorageChanges: 0 },
  // The frozen fixture's chains carry the REAL pre-registry cut-taking Admin facet, so they cross
  // the edge natively — no shim.
  installLegacyCutTakingFacet: false,
  // gwSettled chains are not covered: their upgrade routes through the gateway CTM, which the
  // registry model cannot bump yet (no EraVM-deployable release). Chain 10 (L1-settled) and 11
  // (the gateway itself, which settles on L1) are the supported shapes. The runner keeps only the
  // chains that settle on L1 in the source states, since chains 12 and 14 settle on the gateway in
  // the v0.34.0 states but on L1 in the current config.
  targetRoles: ["directSettled", "gateway"],
  // Runs on the two target chains: the gateway stands in as an ordinary L1-settled peer, being the
  // only other chain the upgrade covers.
  checkInteropGating: true,
  // Then two registry-driven hops on the bootstrapped ecosystem, each departing from the state the
  // previous one left, both driven by the base prepare pipeline and both emitting a governance bundle
  // of exactly the ordered domain-executor legs the hop needs (`applyL1Upgrade` when the ecosystem
  // changes, then `applyCTMUpgrade`).
  followUps: [
    // A same-minor PATCH first: one fresh verifier, published as a release that copies the
    // bootstrap's except that member. It runs while the bootstrap's L2 upgrade transaction is
    // still pending, which a patch is allowed to do and must not disturb, and its routing is
    // identical on both edges so it must derive no facet cut.
    {
      label: "verifier-patch",
      upgradeInputTemplatePath: "test/anvil-interop/config/patch-upgrade.toml",
      expectedProtocolVersion: packProtocolVersion({ ...genesis, patch: genesis.patch + 1 }),
      coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36_1.sol:CoreUpgradeForTests_v36_1",
      ctmScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36_1.sol:CTMUpgradeForTests_v36_1",
      keepsPendingL2Upgrade: true,
      expectsEmptyFacetDelta: true,
    },
    // Then an ordinary MINOR upgrade on top of the patch (the v36 edge): one fresh ecosystem
    // implementation pinned in a Core-domain ProxyUpgradeTransition, and a transition. The ecosystem
    // runs the current sources, so every CTM release member is untouched: the prepare must reuse each of
    // them rather than redeploy the facet set, publishing a copy of the live release one minor up. Its
    // L2 leg is v36's standard one, which runs `L2DefaultUpgrade`.
    {
      label: "recurring",
      upgradeInputTemplatePath: "test/anvil-interop/config/recurring-upgrade.toml",
      expectedProtocolVersion: packProtocolVersion({ major: genesis.major, minor: genesis.minor + 1, patch: 0 }),
      coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36.sol:CoreUpgradeForTests_v36",
      ctmScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36.sol:CTMUpgradeForTests_v36",
      expectsReusedReleaseMembers: true,
      expectsFreshMessageRoot: true,
      carriesL2Upgrade: true,
    },
  ],
})
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Upgrade test failed:", error.message || error);
    process.exit(1);
  });
