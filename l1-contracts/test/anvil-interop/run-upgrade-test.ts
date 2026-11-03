#!/usr/bin/env node

import { readStateVersion, readUpgradeSourceGenesisRoot } from "./src/core/anvil-config";
import { runPipelineUpgradeScenario } from "./src/helpers/pipeline-upgrade-runner";
import { packProtocolVersion, readGenesisSemVer } from "./src/helpers/upgrade-test-utils";

// The previous release's states are built without CBOR metadata, and a prepare decides reuse by comparing code, so
// the prepares protocol-ops runs and the reviewed build hashes come from a build without it too.
process.env.FOUNDRY_PROFILE = "anvil-interop";

// The upgrade the current release ships, applied through protocol-ops to the previous release's ecosystem
// (`upgradeSourceStateVersion` in config/anvil-config.json), then a same-minor patch on top. The target version is
// the one in the ZKsync OS genesis config.
const genesis = readGenesisSemVer();

runPipelineUpgradeScenario({
  label: "release",
  // The FROZEN previous-release fixture (see chain-states/README.md).
  stateVersion: readStateVersion("upgradeSourceStateVersion"),
  permanentValuesTemplatePath: "test/anvil-interop/config/release-permanent-values.toml",
  sourceGenesis: { genesisBatchHash: readUpgradeSourceGenesisRoot(), genesisIndexRepeatedStorageChanges: 0 },
  // gwSettled chains are not covered: their upgrade routes through the gateway CTM, which the
  // registry model cannot bump yet (no EraVM-deployable release). Chain 10 (L1-settled) and 11
  // (the gateway itself, which settles on L1) are the supported shapes.
  targetRoles: ["directSettled", "gateway"],
  hops: [
    // The release's own edge: the CTM side runs the release's script, as protocol-ops prepares it by default; the
    // core side adds the fixture's harness-only `L1ChainAssetHandler` and `L1MessageRoot` to what the release
    // declares (see `CoreUpgradeForTests_v36`).
    {
      label: "release",
      upgradeInputTemplatePath: "test/anvil-interop/config/release-upgrade.toml",
      expectedProtocolVersion: packProtocolVersion(genesis),
      coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36.sol:CoreUpgradeForTests_v36",
    },
    // A same-minor PATCH: one fresh `DiamondInit`, published as a release that copies the live one except that member.
    // Its routing is identical on both edges, so it must derive no facet cut.
    {
      label: "patch",
      upgradeInputTemplatePath: "test/anvil-interop/config/patch-upgrade.toml",
      expectedProtocolVersion: packProtocolVersion({ ...genesis, patch: genesis.patch + 1 }),
      coreScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36_1.sol:CoreUpgradeForTests_v36_1",
      ctmScriptPath: "test/foundry/l1/integration/_EcosystemUpgradeForTests_v36_1.sol:CTMUpgradeForTests_v36_1",
      expectsEmptyFacetDelta: true,
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
