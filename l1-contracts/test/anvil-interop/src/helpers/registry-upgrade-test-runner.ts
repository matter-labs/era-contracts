/**
 * Registry-driven upgrade test runner.
 *
 * Proves the NEW registry-driven upgrade process end-to-end on live anvil chains, mirroring
 * the foundry e2e test `test/foundry/l1/unit/concrete/Upgrades/registry/RegistryDrivenUpgrade.t.sol`
 * but against a fully deployed ecosystem (the pre-generated anvil-interop chain states) and
 * with REAL storage-backed, write-once upgrade objects initialized from the committed manifest:
 *
 *   1. Boot the pre-generated ecosystem (current branch's code) from chain-states/.
 *   2. Deploy the registry-driven machinery on the anvil L1: the two domain-specific executors
 *      (`CTMUpgradeExecutor`, `EcosystemUpgradeExecutor`), plus the new-version implementations
 *      of a synthetic minor version bump (fresh `AdminFacet` as the facet change,
 *      `DefaultUpgrade` as the init contract, fresh `ZKsyncOSTestnetVerifier`, fresh
 *      `DiamondInit`, and a fresh `L1MessageRoot` implementation for the ecosystem leg). Every
 *      codehash-pinned implementation is deployed from the `registry-deterministic` forge
 *      profile output (CBOR-metadata-free ⇒ byte-identical across platforms), and the deployer
 *      key + starting nonce are fixed by the committed chain states, so all addresses AND
 *      codehashes are reproducible run-to-run and machine-to-machine.
 *   3. Deploy the fixed `CTMRelease` + `CTMTransition` + `CoreRegistry` implementations and
 *      initialize them (write-once) from the COMMITTED manifest
 *      scripts/registry-manifests/v32-local.json — the reviewable per-upgrade artifact:
 *      - the RELEASE describes what a chain at the target version IS (complete facet set,
 *        DiamondInit, base-system hashes, genesis params) — version-independent;
 *      - the TRANSITION describes how the CURRENT release becomes that release (facet swaps,
 *        L2 leg, schedule, verifier) and pins both edges: `fromRelease -> newRelease` and
 *        `oldProtocolVersion -> newProtocolVersion`.
 *      Then assert `verifyAll()` against the live deployment. This is the default CONSUME mode:
 *      the manifest is never regenerated here, so any drift between the committed data and the
 *      live/freshly-deployed addresses or codehashes fails loudly. With `REGEN_REGISTRIES=1`
 *      (EMIT mode, `yarn regen:v32-registries`) the runner instead rebuilds the manifest from
 *      the LIVE deployment and writes it to the committed path, then continues exactly like
 *      consume mode — the regenerated manifest is meant to be committed.
 *   4. Hand the CTM to the CTM-BOUND `CTMUpgradeExecutor` through the production surface
 *      (`transferOwnership` + the fixed `acceptCTMOwnership` entrypoint) and the ecosystem
 *      `ProxyAdmin` to its bound `EcosystemUpgradeExecutor` through 1-step `transferOwnership`.
 *   5. Execute the upgrade purely through the executors' fixed entrypoints
 *      (`applyCTMUpgrade(transition)`, `applyL1Upgrade(coreRegistry)`, per-chain
 *      `upgradeChain(transition, chainId)`) — no generic delegatecall modules and no
 *      stage-0/1/2 governance calldata anywhere. The schedule (upgrade timestamp, old-version
 *      deadline) lives IN the transition, not in call arguments.
 *   6. Assert the end state: CTM protocol version bumped, `currentRelease` moved to the target
 *      release, upgrade cut hash committed, new verifier registered, chain diamonds re-pointed
 *      to the fresh facets, chain protocol versions bumped, the committed L2 upgrade tx hash
 *      equal to the transition-composed transaction, and the MessageRoot proxy re-pointed by
 *      the ecosystem executor.
 *   7. Relay the transition-composed L2 upgrade transaction to each target L2 anvil chain
 *      through the real `L2ComplexUpgrader` (impersonating the force deployer), reusing the
 *      existing runner's L2 patching approach.
 *
 * ── Harness patches (deviations from production, mirroring v31-upgrade-test-runner) ──
 *
 * - `clearGenesisUpgradeTxHash` (L1 storage write, slot 0x22): the chains' genesis upgrade
 *   transaction is still pending because no server ever executed a batch on these anvil chains.
 *   In production the server clears this after executing the first batch;
 *   `BaseZkSyncUpgrade._setNewProtocolVersion` correctly reverts with
 *   `PreviousUpgradeNotFinalized` otherwise. Same patch (and justification) as the existing
 *   v31 runner — there is no public API to execute a batch on a sequencer-less anvil chain.
 * - L2 delegate target: the transition pins `delegateTo` (the per-upgrade L2 upgrade
 *   implementation which production force-deploys within the same transaction) at a fixed
 *   address; the harness places a no-op contract there via `anvil_setCode` because the L2
 *   contract deployer built-in on the anvil L2 chains is a silent no-op stub (bytecode cannot
 *   be force-deployed from within the EVM). This synthetic minor bump has no L2 init logic, so
 *   a no-op stand-in is the faithful equivalent.
 *
 * Everything else — ownership handover, migration pausing, transition composition, diamond
 * cuts, `DefaultUpgrade.upgradeFromTransition` init delegatecall, L2 tx commitment,
 * `L2ComplexUpgrader` execution — runs through unpatched production code paths.
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR } from "../core/const";
import {
  getAbi,
  getCreationBytecode,
  getDeterministicBytecode,
  getDeterministicCreationBytecode,
} from "../core/contracts";
import { impersonateAndRun } from "../core/utils";
import { coreInitArgs, releaseInitArgs, transitionInitArgs } from "./registry-manifest";
import type { ChainRole } from "../core/types";
import { clearGenesisUpgradeTxHash, selectUpgradeChains, traceFailedTx } from "./v31-upgrade-test-runner";

// ── Constants ────────────────────────────────────────────────────────

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");

// Packed SemVer layout (contracts/common/libraries/SemVer.sol): major << 64 | minor << 32 | patch.
const SEMVER_MINOR_SHIFT = 32;

// Manifest tag (kept in the JSON for human orientation) and the CTM entry consumed here.
const REGISTRY_TAG = "V32";
const CTM_REGISTRY_NAME = "ZKsyncOS";

// The fixed release/transition/core-registry implementations live here; the incremental forge
// build below keeps their artifacts current before deployment.
const REGISTRY_CONTRACTS_DIR_REL = "contracts/upgrades/registry";
// Committed manifest for the local (chain-states) environment — the reviewable per-upgrade
// artifact the upgrade objects are initialized from. The default CONSUME mode reads it as-is;
// the EMIT mode (REGEN_REGISTRIES=1) rewrites it so the diff can be reviewed and committed.
const REGISTRY_MANIFEST_REL = "scripts/registry-manifests/v32-local.json";

// Set REGEN_REGISTRIES=1 to run in EMIT mode (see module docs).
const REGEN_ENV_VAR = "REGEN_REGISTRIES";

const STALE_REGISTRIES_HINT =
  `committed v32 registry manifest is stale — rerun with ${REGEN_ENV_VAR}=1 ` +
  "(yarn regen:v32-registries in l1-contracts/test/anvil-interop) and commit the result " +
  `(${REGISTRY_MANIFEST_REL}).`;

// Sources compiled with the `registry-deterministic` forge profile (CBOR-metadata-free ⇒
// byte-identical across platforms; see foundry.toml). Everything the committed manifest pins
// a codehash/bytecode-hash for MUST be deployed from this build, otherwise a manifest
// regenerated on one machine would fail verifyAll() on another.
const DETERMINISTIC_FOUNDRY_PROFILE = "registry-deterministic";
const DETERMINISTIC_SOURCES = [
  "contracts/state-transition/chain-deps/facets/Admin.sol",
  "contracts/state-transition/chain-deps/facets/Getters.sol",
  "contracts/state-transition/chain-deps/facets/Executor.sol",
  "contracts/state-transition/chain-deps/facets/Migrator.sol",
  "contracts/state-transition/chain-deps/facets/Committer.sol",
  "contracts/upgrades/DefaultUpgrade.sol",
  "contracts/state-transition/chain-deps/DiamondInit.sol",
  "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol",
  "contracts/core/message-root/L1MessageRoot.sol",
  "contracts/dev-contracts/MockContractDeployer.sol",
];

// Fixed L2 address the transition pins for the upgrade's L2 delegate target (and its unsafe
// force-deployment entry). In production this is where the per-upgrade L2 upgrade
// implementation gets force-deployed by the same transaction; the harness places a no-op
// contract there via anvil_setCode (see module docs above). Any free address works — this one
// sits far away from the reserved system/genesis ranges (0x8000... / 0x10000...).
const L2_UPGRADE_DELEGATE_ADDR = "0x00000000000000000000000000000000000ab001";

// AdminFacet.acceptAdmin() — used to locate the live AdminFacet on the chain diamonds.
const ACCEPT_ADMIN_FRAGMENT = "acceptAdmin";

const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const DEFAULT_GAS_LIMIT = 10_000_000;

// ── Public types ─────────────────────────────────────────────────────

export type RegistryUpgradeScenario = {
  label: string;
  /** chain-states/<stateVersion> to boot from (a fresh ecosystem at the current branch's code). */
  stateVersion: string;
  /** Which chain roles to upgrade. Only L1-settled chains are supported (see assertions). */
  targetRoles: ChainRole[];
};

type ChainTarget = { chainId: number; diamondProxy: string };

// ── Assertion helpers ────────────────────────────────────────────────

function assertEq(actual: unknown, expected: unknown, message: string): void {
  const norm = (v: unknown) => (typeof v === "string" ? v.toLowerCase() : String(v).toLowerCase());
  if (norm(actual) !== norm(expected)) {
    throw new Error(`Assertion failed: ${message}\n  actual:   ${actual}\n  expected: ${expected}`);
  }
  console.log(`  ✓ ${message}`);
}

function assertTrue(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(`Assertion failed: ${message}`);
  }
  console.log(`  ✓ ${message}`);
}

async function sendAndCheck(
  provider: ethers.providers.JsonRpcProvider,
  txPromise: Promise<ethers.providers.TransactionResponse>,
  label: string
): Promise<ethers.providers.TransactionReceipt> {
  const tx = await txPromise;
  const receipt = await tx.wait();
  if (receipt.status !== 1) {
    const trace = await traceFailedTx(provider, receipt.transactionHash);
    throw new Error(`${label} reverted:\n${trace}`);
  }
  return receipt;
}

// ── Main entry point ─────────────────────────────────────────────────

export async function runRegistryDrivenUpgradeScenario(scenario: RegistryUpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const regenRegistries = process.env[REGEN_ENV_VAR] === "1";

  try {
    // ── 1. Boot the pre-generated ecosystem ──
    const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
    if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
      throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, stateDir);
    const upgradeChains = selectUpgradeChains(chainAddresses, chains.config, scenario.targetRoles);
    if (upgradeChains.length === 0) {
      throw new Error(`No chains matched roles ${scenario.targetRoles.join(", ")}`);
    }
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }
    const l1Provider = new ethers.providers.JsonRpcProvider(l1Chain.rpcUrl);
    const deployer = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    const l1ChainId = (await l1Provider.getNetwork()).chainId;

    // ── 2. Read the live upgrade inputs ──
    console.log("\n── Reading live ecosystem state ──");
    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
    const live = await readLiveUpgradeInputs(l1Provider, ctm, upgradeChains, l1Addresses.messageRoot);
    console.log(`  old protocol version: ${live.oldVersionString} (${live.oldVersion.toString()})`);
    console.log(`  new protocol version: ${live.newVersionString} (${live.newVersion.toString()})`);
    console.log(`  current release: ${live.fromRelease}`);
    console.log(`  live AdminFacet: ${live.oldAdminFacet} (${live.adminSelectors.length} selectors)`);

    // ── 3. Deploy the executors + new implementations ──
    console.log("\n── Deploying executors and new-version implementations ──");
    buildDeterministicArtifacts();
    const deployed = await deployUpgradeMachinery(deployer, {
      l1ChainId,
      rollupDAManager: live.rollupDAManager,
      bridgehub: l1Addresses.bridgehub,
      eraGatewayChainId: live.eraGatewayChainId,
      chainAssetHandler: live.chainAssetHandler,
      ctm: ctmAddresses.chainTypeManager,
      ecosystemProxyAdmin: live.ecosystemProxyAdmin,
    });

    // ── 4. Regenerate (EMIT mode) or validate (CONSUME mode) the committed manifest, then
    //       deploy + initialize the release/transition/core registry from it ──
    const manifestPath = path.join(l1ContractsDir, REGISTRY_MANIFEST_REL);
    if (regenRegistries) {
      console.log(`\n── ${REGEN_ENV_VAR}=1: regenerating the committed v32 registry manifest ──`);
      const manifest = await buildRegistryManifest(
        l1Provider,
        live,
        deployed,
        ctmAddresses.chainTypeManager,
        ctmAddresses.releaseFactory
      );
      fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
      fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
      console.log(`  manifest written to ${REGISTRY_MANIFEST_REL}`);
    } else {
      console.log(`\n── Consuming the committed v32 registry manifest (${REGISTRY_MANIFEST_REL}) ──`);
      assertCommittedManifestMatchesLiveDeployment(
        manifestPath,
        live,
        deployed,
        ctmAddresses.chainTypeManager,
        ctmAddresses.releaseFactory
      );
    }
    const objects = await deployUpgradeObjectsFromManifest(
      deployer,
      manifestPath,
      deployed,
      ctmAddresses.releaseFactory
    );
    console.log(`  CTM release:    ${objects.release}`);
    console.log(`  CTM transition: ${objects.transition}`);
    console.log(`  core registry:  ${objects.coreRegistry}`);

    // verifyAll() checks the pinned codehashes of every new implementation against the code
    // actually live on this chain — the staleness gate for the committed manifest. (validate()
    // is the reverting variant the executors call on the execution path.)
    const releaseContract = new ethers.Contract(objects.release, getAbi("ICTMRelease"), l1Provider);
    const transitionContract = new ethers.Contract(objects.transition, getAbi("ICTMTransition"), l1Provider);
    const coreRegistryContract = new ethers.Contract(objects.coreRegistry, getAbi("ICoreRegistry"), l1Provider);
    try {
      assertTrue(await releaseContract.verifyAll(), "CTM release verifyAll() passes on the live deployment");
      assertTrue(await transitionContract.verifyAll(), "CTM transition verifyAll() passes on the live deployment");
      assertTrue(await coreRegistryContract.verifyAll(), "core registry verifyAll() passes on the live deployment");
      assertEq(
        await transitionContract.fromRelease(),
        live.fromRelease,
        "transition departs from the CTM's live current release"
      );
      assertEq(
        (await transitionContract.newProtocolVersion()).toString(),
        live.newVersion.toString(),
        "transition pins the new protocol version"
      );
      // The core registry carries no protocol version and no proxy admin by design —
      // version-schedule identity is owned by the transition, and the ecosystem executor is
      // BOUND to its immutable ProxyAdmin. The registry pins only source-checked rows.
      assertTrue((await coreRegistryContract.ecosystemRows()).length > 0, "core registry pins the ecosystem rows");
    } catch (error) {
      throw regenRegistries ? error : staleRegistriesError(error);
    }

    // ── 5. Authority handover ──
    console.log("\n── Handing CTM + ProxyAdmin authority to the executors ──");
    await handOverAuthority(l1Provider, deployer, {
      ctmExecutor: deployed.ctmExecutor,
      ecoExecutor: deployed.ecoExecutor,
      ctmAddr: ctmAddresses.chainTypeManager,
      proxyAdminAddr: live.ecosystemProxyAdmin,
    });

    // ── 6. Pause migrations (the production prerequisite of setNewVersionUpgrade) ──
    console.log("\n── Pausing chain migrations ──");
    await setMigrationPaused(l1Provider, live.chainAssetHandler, true);

    // ── 7. Execute the registry-driven upgrade through the domain executors ──
    console.log("\n── Executing registry-driven upgrade via the domain executors ──");
    const ctmExecutor = new ethers.Contract(deployed.ctmExecutor, getAbi("CTMUpgradeExecutor"), deployer);
    const ecoExecutor = new ethers.Contract(deployed.ecoExecutor, getAbi("EcosystemUpgradeExecutor"), deployer);

    await sendAndCheck(
      l1Provider,
      ctmExecutor.applyCTMUpgrade(objects.transition, { gasLimit: DEFAULT_GAS_LIMIT }),
      "ctmExecutor.applyCTMUpgrade(transition)"
    );
    console.log("  ✓ applyCTMUpgrade executed");

    await sendAndCheck(
      l1Provider,
      ecoExecutor.applyL1Upgrade(objects.coreRegistry, { gasLimit: DEFAULT_GAS_LIMIT }),
      "ecoExecutor.applyL1Upgrade(coreRegistry)"
    );
    console.log("  ✓ applyL1Upgrade executed");

    // The chains' genesis upgrade tx is still pending on the sequencer-less anvil chains;
    // clear it exactly like the v31 runner does (see module docs).
    await clearGenesisUpgradeTxHash(l1Provider, upgradeChains);

    for (const chain of upgradeChains) {
      await sendAndCheck(
        l1Provider,
        ctmExecutor.upgradeChain(objects.transition, chain.chainId, { gasLimit: DEFAULT_GAS_LIMIT }),
        `ctmExecutor.upgradeChain(transition) for chain ${chain.chainId}`
      );
      console.log(`  ✓ chain ${chain.chainId} upgraded`);
    }

    // ── 8. Unpause migrations (production stage-2 equivalent) ──
    console.log("\n── Unpausing chain migrations ──");
    await setMigrationPaused(l1Provider, live.chainAssetHandler, false);

    // ── 9. L1 assertions ──
    console.log("\n── Verifying L1 end state ──");
    const composerHarness = new ethers.Contract(
      deployed.composerHarness,
      getAbi("RegistryComposerHarness"),
      l1Provider
    );
    const expectedL2TxHash: string = await composerHarness.l2UpgradeTxHash(objects.transition);

    assertEq(
      (await ctm.protocolVersion()).toString(),
      live.newVersion.toString(),
      "CTM protocol version bumped to the transition's new version"
    );
    assertEq(
      await ctm.currentRelease(),
      objects.release,
      "CTM currentRelease moved to the transition's target release"
    );
    assertTrue(
      (await ctm.upgradeCutHash(live.oldVersion)) !== ethers.constants.HashZero,
      "CTM upgradeCutHash committed for the old version"
    );
    assertEq(
      await ctm.protocolVersionVerifier(live.newVersion),
      deployed.newVerifier,
      "CTM registered the fresh verifier for the new version"
    );
    for (const chain of upgradeChains) {
      const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
      assertEq(
        (await diamond.getProtocolVersion()).toString(),
        live.newVersion.toString(),
        `chain ${chain.chainId}: getProtocolVersion() bumped`
      );
      assertEq(
        await diamond.facetAddress(live.acceptAdminSelector),
        deployed.newAdminFacet,
        `chain ${chain.chainId}: AdminFacet re-pointed to the fresh implementation`
      );
      // getProtocolVersion() — a GettersFacet selector — must now route to the fresh instance,
      // proving the multi-facet replacement was applied (spot check; the cut-hash equality
      // below covers the full composed cut).
      assertEq(
        await diamond.facetAddress("0x33ce93fe"),
        deployed.newGettersFacet,
        `chain ${chain.chainId}: GettersFacet re-pointed to the fresh implementation`
      );
      assertEq(
        await diamond.getVerifier(),
        deployed.newVerifier,
        `chain ${chain.chainId}: verifier switched to the fresh instance`
      );
      assertEq(
        await diamond.getL2SystemContractsUpgradeTxHash(),
        expectedL2TxHash,
        `chain ${chain.chainId}: committed L2 upgrade tx hash equals the transition-composed transaction`
      );
    }
    const implSlot = await l1Provider.getStorageAt(l1Addresses.messageRoot, EIP1967_IMPL_SLOT);
    assertEq(
      ethers.utils.getAddress("0x" + implSlot.slice(26)),
      deployed.newMessageRootImpl,
      "MessageRoot proxy re-pointed to the fresh implementation by EcosystemUpgradeExecutor"
    );

    // ── 10. Relay the composed L2 upgrade tx to each target L2 chain ──
    console.log("\n── Relaying the transition-composed L2 upgrade transaction ──");
    const composedTx = await composerHarness.l2UpgradeTx(objects.transition);
    for (const chain of upgradeChains) {
      const l2Chain = anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
      if (!l2Chain) {
        throw new Error(`Missing running L2 chain ${chain.chainId}`);
      }
      const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
      await relayL2UpgradeTx(l2Provider, composedTx.data, chain.chainId);
    }

    console.log("\n✅ Registry-driven upgrade verified successfully!\n");
    if (regenRegistries) {
      console.log(`Regenerated ${REGISTRY_MANIFEST_REL} — review the diff and commit it.\n`);
    }
  } finally {
    if (!keepChains) {
      await anvilManager.stopAll();
    }
  }
}

// ── Live state readers ───────────────────────────────────────────────

type LiveUpgradeInputs = {
  oldVersion: ethers.BigNumber;
  newVersion: ethers.BigNumber;
  oldVersionString: string;
  newVersionString: string;
  /** The CTM's live `currentRelease` — the release edge the transition must depart from. */
  fromRelease: string;
  oldAdminFacet: string;
  adminSelectors: string[];
  otherFacets: { name: string; address: string }[];
  acceptAdminSelector: string;
  genesisUpgrade: string;
  rollupDAManager: string;
  chainAssetHandler: string;
  eraGatewayChainId: ethers.BigNumber;
  ecosystemProxyAdmin: string;
  messageRootProxy: string;
  /** The proxy's live (pre-upgrade) implementation — the source side of the ecosystem edge. */
  messageRootImplOld: string;
  /** Live complete base-system hashes — the release carries complete target values. */
  bootloaderHash: string;
  defaultAccountHash: string;
  evmEmulatorHash: string;
};

/** The probed live facet address by name (see readLiveUpgradeInputs facet probes). */
function liveFacet(live: LiveUpgradeInputs, name: string): string {
  const entry = live.otherFacets.find((f) => f.name === name);
  if (!entry) {
    throw new Error(`live facet ${name} was not probed`);
  }
  return entry.address;
}

async function readLiveUpgradeInputs(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctm: ethers.Contract,
  upgradeChains: ChainTarget[],
  messageRootProxy: string
): Promise<LiveUpgradeInputs> {
  const oldVersion: ethers.BigNumber = await ctm.protocolVersion();
  const minorShift = ethers.BigNumber.from(2).pow(SEMVER_MINOR_SHIFT);
  if (!oldVersion.mod(minorShift).isZero() || !oldVersion.div(minorShift).lt(minorShift)) {
    // The synthetic bump below assumes a plain 0.<minor>.0 version.
    throw new Error(`Unexpected packed protocol version ${oldVersion.toString()}`);
  }
  const oldMinor = oldVersion.div(minorShift).toNumber();
  const newVersion = ethers.BigNumber.from(oldMinor + 1).mul(minorShift);

  // The release edge: the chain states are a registry-era deployment, so the CTM must already
  // carry a genesis release. (A zero fromRelease is migration-only semantics — v31 -> v32.)
  const fromRelease: string = await ctm.currentRelease();
  if (fromRelease === ethers.constants.AddressZero) {
    throw new Error("live CTM has no currentRelease — regenerate the chain states from registry-era code");
  }

  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
  const acceptAdminSelector = adminIface.getSighash(ACCEPT_ADMIN_FRAGMENT);

  // Locate the live AdminFacet (address + installed selectors) on the first target chain and
  // check that every target chain shares it — the release pins ONE facet set.
  const firstDiamond = new ethers.Contract(upgradeChains[0].diamondProxy, getAbi("GettersFacet"), l1Provider);
  const oldAdminFacet: string = await firstDiamond.facetAddress(acceptAdminSelector);
  const adminSelectors: string[] = await firstDiamond.facetFunctionSelectors(oldAdminFacet);

  // Locate the remaining live facets by probing one representative selector each, so the
  // release can pin (and verifyAll() can cover) the complete facet surface, not only the
  // facets this synthetic bump replaces.
  const facetProbes: { name: string; selector: string }[] = [
    { name: "GettersFacet", selector: "0x33ce93fe" }, // getProtocolVersion()
    { name: "MailboxFacet", selector: "0x12f43dab" }, // bridgehubRequestL2Transaction(...)
    { name: "ExecutorFacet", selector: "0xa085344d" }, // executeBatchesSharedBridge(...)
    { name: "MigratorFacet", selector: "0x64b554ad" }, // forwardedBridgeBurn(...)
    { name: "CommitterFacet", selector: "0x0db9eb87" }, // commitBatchesSharedBridge(...)
  ];
  const otherFacets: { name: string; address: string }[] = [];
  for (const probe of facetProbes) {
    const facetAddress: string = await firstDiamond.facetAddress(probe.selector);
    if (facetAddress === ethers.constants.AddressZero) {
      throw new Error(`Probe selector for ${probe.name} is not installed on the live diamond`);
    }
    otherFacets.push({ name: probe.name, address: facetAddress });
  }
  for (const chain of upgradeChains) {
    const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
    const facet: string = await diamond.facetAddress(acceptAdminSelector);
    if (facet.toLowerCase() !== oldAdminFacet.toLowerCase()) {
      throw new Error(`Chain ${chain.chainId} has a different AdminFacet (${facet}); the release pins one facet set`);
    }
    const isZKsyncOS: boolean = await diamond.getZKsyncOS();
    if (!isZKsyncOS) {
      throw new Error(`Chain ${chain.chainId} is not a ZKsyncOS chain; this runner pins a ${CTM_REGISTRY_NAME} CTM`);
    }
    const settlementLayer: string = await diamond.getSettlementLayer();
    if (settlementLayer !== ethers.constants.AddressZero) {
      throw new Error(`Chain ${chain.chainId} does not settle on L1; only L1-settled chains are supported`);
    }
  }

  // Live complete base-system hashes: the release describes the complete post-upgrade state,
  // and this synthetic bump does not change them.
  const bootloaderHash: string = await firstDiamond.getL2BootloaderBytecodeHash();
  const defaultAccountHash: string = await firstDiamond.getL2DefaultAccountBytecodeHash();
  const evmEmulatorHash: string = await firstDiamond.getL2EvmEmulatorBytecodeHash();

  const adminFacetView = new ethers.Contract(upgradeChains[0].diamondProxy, getAbi("AdminFacet"), l1Provider);
  const rollupDAManager: string = await adminFacetView.getRollupDAManager();

  const genesisUpgrade: string = await ctm.l1GenesisUpgrade();

  const bridgehubAddr: string = await ctm.BRIDGE_HUB();
  const bridgehub = new ethers.Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Provider);
  const chainAssetHandler: string = await bridgehub.chainAssetHandler();

  const messageRoot = new ethers.Contract(messageRootProxy, getAbi("L1MessageRoot"), l1Provider);
  const eraGatewayChainId: ethers.BigNumber = await messageRoot.ERA_GATEWAY_CHAIN_ID();
  const adminSlotRaw = await l1Provider.getStorageAt(
    messageRootProxy,
    // EIP-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
  );
  const ecosystemProxyAdmin = ethers.utils.getAddress("0x" + adminSlotRaw.slice(26));
  const implSlotRaw = await l1Provider.getStorageAt(messageRootProxy, EIP1967_IMPL_SLOT);
  const messageRootImplOld = ethers.utils.getAddress("0x" + implSlotRaw.slice(26));

  const toVersionString = (v: ethers.BigNumber) => `0.${v.div(minorShift).toString()}.0`;
  return {
    oldVersion,
    newVersion,
    oldVersionString: toVersionString(oldVersion),
    newVersionString: toVersionString(newVersion),
    fromRelease,
    oldAdminFacet,
    adminSelectors,
    otherFacets,
    acceptAdminSelector,
    genesisUpgrade,
    rollupDAManager,
    chainAssetHandler,
    eraGatewayChainId,
    ecosystemProxyAdmin,
    messageRootProxy,
    messageRootImplOld,
    bootloaderHash,
    defaultAccountHash,
    evmEmulatorHash,
  };
}

// ── Deployment ───────────────────────────────────────────────────────

type DeployedMachinery = {
  transitionFactory: string;
  coreRegistryFactory: string;
  ctmExecutor: string;
  ecoExecutor: string;
  composerHarness: string;
  newAdminFacet: string;
  newGettersFacet: string;
  newExecutorFacet: string;
  newMigratorFacet: string;
  newCommitterFacet: string;
  newDefaultUpgrade: string;
  newDiamondInit: string;
  newVerifier: string;
  newMessageRootImpl: string;
};

async function deployUpgradeMachinery(
  deployer: ethers.Wallet,
  params: {
    l1ChainId: number;
    rollupDAManager: string;
    bridgehub: string;
    eraGatewayChainId: ethers.BigNumber;
    chainAssetHandler: string;
    ctm: string;
    ecosystemProxyAdmin: string;
  }
): Promise<DeployedMachinery> {
  const deployFrom = async (
    name: Parameters<typeof getAbi>[0],
    creationBytecode: string,
    args: unknown[]
  ): Promise<string> => {
    const factory = new ethers.ContractFactory(getAbi(name), creationBytecode, deployer);
    const contract = await factory.deploy(...args);
    await contract.deployed();
    console.log(`  ${name}: ${contract.address}`);
    return contract.address;
  };
  const deploy = (name: Parameters<typeof getAbi>[0], args: unknown[]) =>
    deployFrom(name, getCreationBytecode(name), args);
  // The committed manifest pins these contracts' codehashes, so they are deployed from the
  // deterministic (CBOR-metadata-free) build — see buildDeterministicArtifacts().
  const deployPinned = (name: Parameters<typeof getAbi>[0], args: unknown[]) =>
    deployFrom(name, getDeterministicCreationBytecode(name), args);

  // NOTE: the deploy ORDER below is part of the committed manifest's contract: the deployer
  // key + starting nonce are fixed by the chain states, so each contract's address is a pure
  // function of its position in this sequence. Reordering/inserting deploys invalidates the
  // committed manifest (rerun with REGEN_REGISTRIES=1).
  // The trusted factories deploy FIRST: each executor is BOUND to its factory (and its
  // authority target) at construction — factory provenance is what it enforces on every
  // transition / core registry it accepts.
  const transitionFactory = await deploy("CTMTransitionFactory", []);
  const coreRegistryFactory = await deploy("CoreRegistryFactory", []);
  return {
    transitionFactory,
    coreRegistryFactory,
    // The deployer plays the role of protocol governance AND (for this harness) the break-glass
    // governor; each executor is BOUND to its immutable authority targets at construction.
    ctmExecutor: await deploy("CTMUpgradeExecutor", [
      deployer.address,
      deployer.address,
      params.ctm,
      transitionFactory,
    ]),
    ecoExecutor: await deploy("EcosystemUpgradeExecutor", [
      deployer.address,
      deployer.address,
      params.ecosystemProxyAdmin,
      coreRegistryFactory,
    ]),
    composerHarness: await deploy("RegistryComposerHarness", []),
    // The synthetic v-bump's "changed facet": a fresh AdminFacet built from the same source,
    // constructed with the live RollupDAManager so DA-validation behavior is unchanged.
    newAdminFacet: await deployPinned("AdminFacet", [params.l1ChainId, params.rollupDAManager]),
    // The rest of the replaced facet set — a representative multi-facet upgrade. Constructor
    // args mirror the live deployment (config: era testnet, l1ChainId). MailboxFacet is the one
    // facet NOT replaced: its constructor needs the live EIP7702Checker address, which only the
    // original deployment config knows (a real upgrade-prepare pipeline has it; this harness
    // pins Mailbox old == new instead).
    newGettersFacet: await deployPinned("GettersFacet", []),
    newExecutorFacet: await deployPinned("ExecutorFacet", [params.l1ChainId]),
    newMigratorFacet: await deployPinned("MigratorFacet", [params.l1ChainId, true /* _isTestnet */]),
    newCommitterFacet: await deployPinned("CommitterFacet", [params.l1ChainId]),
    newDefaultUpgrade: await deployPinned("DefaultUpgrade", []),
    newDiamondInit: await deployPinned("DiamondInit", [true /* _isZKOS */]),
    // Real verifier contract for the new version (same type the ZKsyncOS CTM uses). The proof
    // sub-verifiers are zero like in the foundry e2e test — no proofs are verified here.
    newVerifier: await deployPinned("ZKsyncOSTestnetVerifier", [
      ethers.constants.AddressZero,
      ethers.constants.AddressZero,
      deployer.address,
    ]),
    // Ecosystem leg: a fresh L1MessageRoot implementation with the live immutable values.
    newMessageRootImpl: await deployPinned("L1MessageRoot", [
      params.bridgehub,
      params.eraGatewayChainId,
      params.chainAssetHandler,
    ]),
  };
}

// ── Manifest generation ──────────────────────────────────────────────

async function buildRegistryManifest(
  l1Provider: ethers.providers.JsonRpcProvider,
  live: LiveUpgradeInputs,
  deployed: DeployedMachinery,
  ctmProxy: string,
  releaseFactoryAddr: string
): Promise<Record<string, unknown>> {
  const codehash = async (addr: string) => ethers.utils.keccak256(await l1Provider.getCode(addr));

  // The L2 leg of the synthetic bump: unsafe-force-deploy the (no-op) L2 upgrade
  // implementation at the pinned delegate address, then delegatecall it — the exact shape of a
  // production ZKsyncOS upgrade transaction. The bytecode info describes the no-op stand-in
  // the harness places at that address (see relayL2UpgradeTx).
  const delegateBytecode = getDeterministicBytecode("MockContractDeployer");
  const delegateCodeHash = ethers.utils.keccak256(delegateBytecode);
  const deployedBytecodeInfo = ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint256", "bytes32"],
    [delegateCodeHash, ethers.utils.hexDataLength(delegateBytecode), delegateCodeHash]
  );

  // Production freezability flags (DeployCTMUtils facet cuts).
  const freezability: Record<string, boolean> = {
    AdminFacet: false,
    GettersFacet: false,
    MailboxFacet: true,
    ExecutorFacet: true,
    MigratorFacet: false,
    CommitterFacet: true,
  };

  // The RELEASE's genesis facets: the complete post-upgrade facet surface. NO facet swaps are
  // authored anywhere — the transition DERIVES its delta on-chain from (fromRelease,
  // newRelease) at initialization. Five facets get fresh implementations; MailboxFacet keeps
  // its live address (unchanged by this bump, so the derived delta contains no row for it).
  // Explicit routing is captured from each facet's own self-description at BUILD time, and
  // every row carries its inline codehash pin.
  const installedFacets = [
    { name: "AdminFacet", address: deployed.newAdminFacet },
    { name: "GettersFacet", address: deployed.newGettersFacet },
    { name: "ExecutorFacet", address: deployed.newExecutorFacet },
    { name: "MigratorFacet", address: deployed.newMigratorFacet },
    { name: "CommitterFacet", address: deployed.newCommitterFacet },
    { name: "MailboxFacet", address: liveFacet(live, "MailboxFacet") },
  ];
  const genesisFacets = [];
  for (const { name, address } of installedFacets) {
    const selfDescribing = new ethers.Contract(address, getAbi("ISelfDescribingFacet"), l1Provider);
    genesisFacets.push({
      name,
      address,
      codehash: await codehash(address),
      isFreezable: freezability[name],
      selectors: await selfDescribing.selectors(),
    });
  }

  return {
    tag: REGISTRY_TAG,
    oldVersion: live.oldVersionString,
    newVersion: live.newVersionString,
    core: {
      // Source-checked edges: the proxy must currently point at `expectedOldImpl` for the row
      // to apply — replaying a stale registry can never downgrade a proxy. No proxy admin: the
      // ecosystem executor is BOUND to its immutable ProxyAdmin.
      contracts: {
        L1MessageRoot: {
          proxy: live.messageRootProxy,
          expectedOldImpl: live.messageRootImplOld,
          implNew: deployed.newMessageRootImpl,
          implNewCodehash: await codehash(deployed.newMessageRootImpl),
        },
      },
    },
    ctms: [
      {
        name: CTM_REGISTRY_NAME,
        isZKsyncOS: true,
        ctmProxy,
        // What a chain at the target release IS — version-independent reusable chain state.
        release: {
          diamondInit: { address: deployed.newDiamondInit, codehash: await codehash(deployed.newDiamondInit) },
          genesisFacets,
          // Complete target values (this bump changes none of them, so they equal the live ones
          // and the DERIVED hash changes are zero).
          baseSystemContracts: {
            bootloader: live.bootloaderHash,
            defaultAccount: live.defaultAccountHash,
            evmEmulator: live.evmEmulatorHash,
          },
          // Chain-creation payload for chains created at this release. No new chain is created
          // in this test, so a synthetic payload (mirroring the foundry e2e test) suffices.
          fixedForceDeploymentsData: "0xf1f2",
          genesis: {
            genesisUpgrade: { address: live.genesisUpgrade, codehash: await codehash(live.genesisUpgrade) },
            batchHash: ethers.utils.hexZeroPad("0x01", 32),
            // ZKsyncOSChainTypeManager requires the genesis batch commitment to be exactly 1.
            batchCommitment: ethers.utils.hexZeroPad("0x01", 32),
            indexRepeatedStorageChanges: 54,
          },
        },
        // How the current release becomes that release. The `newRelease` edge is the deployed
        // CTMRelease address (nonce-deterministic, passed by the runner at initialization);
        // `fromRelease` is the CTM's live current release.
        transition: {
          // The canonical factory attesting BOTH release edges (the chain states' factory).
          releaseFactory: releaseFactoryAddr,
          fromRelease: live.fromRelease,
          verifier: { address: deployed.newVerifier, codehash: await codehash(deployed.newVerifier) },
          upgradeEngine: {
            address: deployed.newDefaultUpgrade,
            codehash: await codehash(deployed.newDefaultUpgrade),
          },
          // Schedule: immediately executable, old version stays usable indefinitely.
          oldProtocolVersionDeadline: ethers.constants.MaxUint256.toHexString(),
          upgradeTimestamp: 0,
          // No facet swaps and no hash changes here: both are DERIVED on-chain from the
          // (fromRelease, newRelease) pair at transition initialization.
          l2Plan: {
            deployments: [
              {
                upgradeType: "ZKsyncOSUnsafeForceDeployment",
                deployedBytecodeInfo,
                newAddress: L2_UPGRADE_DELEGATE_ADDR,
              },
            ],
            delegateTo: L2_UPGRADE_DELEGATE_ADDR,
            delegateCalldata: "0x",
            factoryDepHashes: [],
          },
        },
      },
    ],
  };
}

/**
 * Compile the codehash-pinned sources with the `registry-deterministic` forge profile
 * (CBOR-metadata-free ⇒ byte-identical across platforms) into out-registry-deterministic/.
 * Both modes run this: emit pins the resulting codehashes, consume deploys the exact same
 * bytecode so verifyAll() can hold.
 */
function buildDeterministicArtifacts(): void {
  console.log(`  compiling pinned sources with FOUNDRY_PROFILE=${DETERMINISTIC_FOUNDRY_PROFILE}…`);
  execSync(`forge build ${DETERMINISTIC_SOURCES.join(" ")}`, {
    cwd: l1ContractsDir,
    stdio: "inherit",
    env: { ...process.env, FOUNDRY_PROFILE: DETERMINISTIC_FOUNDRY_PROFILE },
  });
}

function staleRegistriesError(cause: unknown): Error {
  const message = cause instanceof Error ? cause.message : String(cause);
  return new Error(`${message}\n\n${STALE_REGISTRIES_HINT}`);
}

/**
 * CONSUME mode gate: the committed manifest must describe exactly the live deployment this run
 * produced — same protocol versions, same live (old) addresses from the chain states, and the
 * same nonce-deterministic freshly deployed implementation addresses. Any drift means the
 * committed manifest was generated against different code/states and must be regenerated.
 */
function assertCommittedManifestMatchesLiveDeployment(
  manifestPath: string,
  live: LiveUpgradeInputs,
  deployed: DeployedMachinery,
  ctmProxy: string,
  releaseFactoryAddr: string
): void {
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`Committed registry manifest not found at ${manifestPath}.\n\n${STALE_REGISTRIES_HINT}`);
  }
  // Same shape as the object built by buildRegistryManifest (the emit-mode output).
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
  const ctm = (manifest.ctms || []).find((c: { name?: string }) => c.name === CTM_REGISTRY_NAME);
  const genesisFacet = (name: string) =>
    (ctm?.release?.genesisFacets || []).find((f: { name?: string }) => f.name === name);
  const checks: Array<[string, unknown, unknown]> = [
    ["tag", manifest.tag, REGISTRY_TAG],
    ["oldVersion", manifest.oldVersion, live.oldVersionString],
    ["newVersion", manifest.newVersion, live.newVersionString],
    ["core.contracts.L1MessageRoot.proxy", manifest.core?.contracts?.L1MessageRoot?.proxy, live.messageRootProxy],
    [
      "core.contracts.L1MessageRoot.expectedOldImpl",
      manifest.core?.contracts?.L1MessageRoot?.expectedOldImpl,
      live.messageRootImplOld,
    ],
    [
      "core.contracts.L1MessageRoot.implNew",
      manifest.core?.contracts?.L1MessageRoot?.implNew,
      deployed.newMessageRootImpl,
    ],
    ["ctm.ctmProxy", ctm?.ctmProxy, ctmProxy],
    ["ctm.transition.fromRelease", ctm?.transition?.fromRelease, live.fromRelease],
    ["ctm.transition.releaseFactory", ctm?.transition?.releaseFactory, releaseFactoryAddr],
    ["ctm.transition.verifier.address", ctm?.transition?.verifier?.address, deployed.newVerifier],
    ["ctm.transition.upgradeEngine.address", ctm?.transition?.upgradeEngine?.address, deployed.newDefaultUpgrade],
    // No facet swaps in the manifest at all: the delta is DERIVED on-chain from the release
    // pair, so the reviewable artifact carries only the two releases' complete routing.
    ["ctm.transition.facetSwaps", ctm?.transition?.facetSwaps === undefined, true],
    ["ctm.release.genesisFacets[AdminFacet].address", genesisFacet("AdminFacet")?.address, deployed.newAdminFacet],
    [
      "ctm.release.genesisFacets[MailboxFacet].address",
      genesisFacet("MailboxFacet")?.address,
      liveFacet(live, "MailboxFacet"),
    ],
    ["ctm.release.diamondInit.address", ctm?.release?.diamondInit?.address, deployed.newDiamondInit],
    ["ctm.release.genesis.genesisUpgrade.address", ctm?.release?.genesis?.genesisUpgrade?.address, live.genesisUpgrade],
  ];
  const mismatches = checks
    .filter(([, actual, expected]) => String(actual).toLowerCase() !== String(expected).toLowerCase())
    .map(([label, actual, expected]) => `  ${label}: manifest has ${actual}, live deployment has ${expected}`);
  if (mismatches.length > 0) {
    throw new Error(
      `Committed registry manifest ${REGISTRY_MANIFEST_REL} does not match the live deployment:\n` +
        `${mismatches.join("\n")}\n\n${STALE_REGISTRIES_HINT}`
    );
  }
  console.log("  ✓ committed manifest matches the live deployment (addresses + versions)");
}

/**
 * Deploy the fixed release/transition/core-registry implementations and initialize them
 * (write-once) from the committed manifest, THROUGH the atomic deploy-and-initialize factories
 * — the production surface (`new <Type>Factory()` then `factory.deploy<Type>(manifest)` in one
 * transaction, so no uninitialized, front-runnable instance ever exists). The release deploys
 * first — transition initialization validates its target release, so the ordering is
 * functional, not stylistic. Artifacts come from the regular forge build; the incremental
 * build below makes sure they are present and current.
 */
async function deployUpgradeObjectsFromManifest(
  deployer: ethers.Wallet,
  manifestPath: string,
  deployed: DeployedMachinery,
  releaseFactoryAddr: string
): Promise<{ release: string; transition: string; coreRegistry: string }> {
  execSync(`forge build ${REGISTRY_CONTRACTS_DIR_REL}`, { cwd: l1ContractsDir, stdio: "inherit" });

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
  const ctm = (manifest.ctms || []).find((c: { name?: string }) => c.name === CTM_REGISTRY_NAME);
  if (!ctm) {
    throw new Error(`manifest has no "${CTM_REGISTRY_NAME}" CTM entry`);
  }

  // Atomic, idempotent deployOrGet through PRE-DEPLOYED factory instances: the release goes
  // through the CHAIN-STATE factory (the one that attested the genesis release — the
  // transition's `releaseFactory` must attest BOTH edges), the transition and core registry
  // through the executor-bound factories.
  const callFactory = async (
    factoryName: "CTMReleaseFactory" | "CTMTransitionFactory" | "CoreRegistryFactory",
    factoryAddr: string,
    method: string,
    initArgs: unknown
  ): Promise<string> => {
    const factory = new ethers.Contract(factoryAddr, getAbi(factoryName), deployer);
    // callStatic yields the instance address for BOTH branches (fresh deploy and deployOrGet
    // hit); the real transaction then lands the state.
    const instance = (await factory.callStatic[method](initArgs)) as string;
    await (await factory[method](initArgs)).wait();
    return instance;
  };

  const release = await callFactory(
    "CTMReleaseFactory",
    releaseFactoryAddr,
    "deployOrGetRelease",
    releaseInitArgs(ctm)
  );
  return {
    release,
    transition: await callFactory(
      "CTMTransitionFactory",
      deployed.transitionFactory,
      "deployOrGetTransition",
      transitionInitArgs(manifest, ctm, release)
    ),
    coreRegistry: await callFactory(
      "CoreRegistryFactory",
      deployed.coreRegistryFactory,
      "deployOrGetCoreRegistry",
      coreInitArgs(manifest)
    ),
  };
}

// ── Authority handover ───────────────────────────────────────────────

async function handOverAuthority(
  l1Provider: ethers.providers.JsonRpcProvider,
  deployer: ethers.Wallet,
  params: { ctmExecutor: string; ecoExecutor: string; ctmAddr: string; proxyAdminAddr: string }
): Promise<void> {
  // CTM (Ownable2Step): transferOwnership from the current owner, then accept through the
  // executor's FIXED acceptCTMOwnership entrypoint — no break-glass involved in the standard
  // handover (forward is a separately governed emergency capability).
  const ctmOwnable = new ethers.Contract(params.ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const ctmOwner: string = await ctmOwnable.owner();
  await impersonateAndRun(l1Provider, ctmOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      ctmOwnable.connect(signer).transferOwnership(params.ctmExecutor, { gasLimit: DEFAULT_GAS_LIMIT }),
      "CTM transferOwnership(ctmExecutor)"
    );
  });
  const ctmExecutor = new ethers.Contract(params.ctmExecutor, getAbi("CTMUpgradeExecutor"), deployer);
  await sendAndCheck(
    l1Provider,
    ctmExecutor.acceptCTMOwnership({ gasLimit: DEFAULT_GAS_LIMIT }),
    "ctmExecutor.acceptCTMOwnership()"
  );
  console.log("  ✓ CTM ownership accepted through the fixed handover entrypoint");

  // Ecosystem ProxyAdmin (1-step Ownable): the current owner (governance in the pre-generated
  // states) hands it to the ecosystem executor directly.
  const proxyAdmin = new ethers.Contract(params.proxyAdminAddr, getAbi("ProxyAdmin"), l1Provider);
  const proxyAdminOwner: string = await proxyAdmin.owner();
  if (proxyAdminOwner.toLowerCase() !== params.ecoExecutor.toLowerCase()) {
    await impersonateAndRun(l1Provider, proxyAdminOwner, async (signer) => {
      await sendAndCheck(
        l1Provider,
        proxyAdmin.connect(signer).transferOwnership(params.ecoExecutor, { gasLimit: DEFAULT_GAS_LIMIT }),
        "ProxyAdmin transferOwnership(ecoExecutor)"
      );
    });
  }
  console.log("  ✓ ecosystem ProxyAdmin owned by ecoExecutor");
}

async function setMigrationPaused(
  l1Provider: ethers.providers.JsonRpcProvider,
  chainAssetHandler: string,
  paused: boolean
): Promise<void> {
  const cah = new ethers.Contract(chainAssetHandler, getAbi("L1ChainAssetHandler"), l1Provider);
  const owner: string = await cah.owner();
  await impersonateAndRun(l1Provider, owner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      (paused ? cah.connect(signer).pauseMigration : cah.connect(signer).unpauseMigration)({
        gasLimit: DEFAULT_GAS_LIMIT,
      }),
      paused ? "ChainAssetHandler.pauseMigration" : "ChainAssetHandler.unpauseMigration"
    );
  });
  console.log(`  ✓ migrationPaused = ${paused}`);
}

// ── L2 relay ─────────────────────────────────────────────────────────

/**
 * Relay the transition-composed L2 upgrade transaction to an L2 anvil chain through the real
 * `L2ComplexUpgrader` (at 0x800f in the pre-generated states).
 *
 * The only patch: the no-op L2 upgrade implementation is placed at the transition-pinned
 * delegate address via anvil_setCode, because the contract-deployer built-in at 0x8006 is a
 * silent no-op stub on the anvil L2 chains (EVM contracts cannot force-deploy bytecode). The
 * transaction data itself is the UNCHANGED composed calldata: the real ComplexUpgrader
 * authenticates the force deployer, decodes the universal force deployment, performs the
 * (no-op) deployer call and delegatecalls the pinned upgrade implementation.
 */
async function relayL2UpgradeTx(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string,
  chainId: number
): Promise<void> {
  await l2Provider.send("anvil_setCode", [L2_UPGRADE_DELEGATE_ADDR, getDeterministicBytecode("MockContractDeployer")]);

  const txHash = await impersonateAndRun(l2Provider, L2_FORCE_DEPLOYER_ADDR, async (signer) => {
    const tx = await signer.sendTransaction({
      to: L2_COMPLEX_UPGRADER_ADDR,
      data: upgradeTxData,
      gasLimit: 30_000_000,
    });
    return tx.hash;
  });
  const receipt = await l2Provider.waitForTransaction(txHash);
  if (receipt.status !== 1) {
    const trace = await traceFailedTx(l2Provider, receipt.transactionHash);
    throw new Error(`Chain ${chainId}: L2 upgrade relay reverted:\n${trace}`);
  }
  console.log(`  ✓ chain ${chainId}: composed L2 upgrade tx executed through L2ComplexUpgrader (${txHash})`);
}
