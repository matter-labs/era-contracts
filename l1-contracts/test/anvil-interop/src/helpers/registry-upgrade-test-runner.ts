/**
 * Registry-driven upgrade test runner: the recurring edge ("v35 -> v36") on an ecosystem that was
 * born into the registry model, mirroring the foundry e2e test
 * `test/foundry/l1/unit/concrete/Upgrades/registry/RegistryDrivenUpgrade.t.sol` with real
 * write-once upgrade objects built from the committed manifest:
 *
 *   1. Boot the ecosystem of the current sources: the `stateVersion` chain states, or a fresh
 *      deployment with `ANVIL_INTEROP_FRESH_DEPLOY=1`.
 *   2. Discover the upgrade executors the deployment created from chain (CTM owner = CTM executor,
 *      its `coordinator()`, the coordinator's `CORE_EXECUTOR()`) and assert the bound shape a fresh
 *      ecosystem is born with — nothing is bootstrapped here.
 *   3. Deploy the new-version implementations of a synthetic minor bump (fresh facets except
 *      Mailbox, `DefaultUpgrade` engine, verifier, `DiamondInit`, and an `L1MessageRoot`
 *      implementation for the ecosystem leg) from the `registry-deterministic` forge profile. The
 *      deployer key and starting nonce are fixed by the chain states, so their addresses are
 *      reproducible run-to-run and machine-to-machine.
 *   4. CONSUME the committed manifest scripts/registry-manifests/v35-local.json (any drift from the
 *      live deployment fails), or with `REGEN_REGISTRIES=1` EMIT it from the live deployment; then
 *      deploy the `CTMRelease` / `CoreTransition` / `CTMTransition` from it and `validate()` them.
 *      The transition departs from the CTM's live `currentRelease`.
 *   5. Drive the operation through the existing coordinator's `stage0/1/2` and each chain through
 *      the CTM executor's `upgradeChain`, every call sent by the executor's live owner
 *      (impersonated).
 *   6. Assert the L1 end state, then relay each chain's transition-composed L2 upgrade transaction
 *      through the real `L2ComplexUpgrader`.
 *
 * Harness patches (deviations from production):
 * - `clearGenesisUpgradeTxHash`: no server ever executes a batch on these anvil chains, so the
 *   genesis upgrade transaction stays pending and would block the bump (`PreviousUpgradeNotFinalized`).
 * - The transition's L2 delegate is placed at its derived address with `anvil_setCode`: the anvil
 *   L2 contract deployer is a no-op stub. The synthetic bump has no L2 init logic, so the no-op
 *   `MockContractDeployer` stand-in is the faithful equivalent.
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import type { FullDeploymentResult } from "../deployment-runner";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  EIP1967_ADMIN_SLOT,
  EIP1967_IMPL_SLOT,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
} from "../core/const";
import {
  getAbi,
  getCreationBytecode,
  getDeterministicBytecode,
  getDeterministicCreationBytecode,
} from "../core/contracts";
import { createProvider, impersonateAndRun } from "../core/utils";
import {
  coreInitArgs,
  emptyTableForceDeploymentsData,
  operationInitArgs,
  releaseInitArgs,
  transitionInitArgs,
} from "./registry-manifest";
import { assertServerNotifierState } from "./bootstrap-upgrade-stage";
import type { ChainRole } from "../core/types";
import { clearGenesisUpgradeTxHash, selectUpgradeChains, traceFailedTx } from "./upgrade-test-utils";

// ── Constants ────────────────────────────────────────────────────────

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");

// Packed SemVer layout (contracts/common/libraries/SemVer.sol): major << 64 | minor << 32 | patch.
const SEMVER_MINOR_SHIFT = 32;

// Manifest tag (kept in the JSON for human orientation) and the CTM entry consumed here.
const REGISTRY_TAG = "V35";
const CTM_REGISTRY_NAME = "ZKsyncOS";

// Committed manifest for the local (chain-states) environment. CONSUME mode reads it as-is; EMIT
// mode (REGEN_REGISTRIES=1) rewrites it so the diff can be reviewed and committed.
const REGISTRY_MANIFEST_REL = "scripts/registry-manifests/v35-local.json";

const REGEN_ENV_VAR = "REGEN_REGISTRIES";
const FRESH_DEPLOY_ENV_VAR = "ANVIL_INTEROP_FRESH_DEPLOY";

const STALE_REGISTRIES_HINT =
  `committed registry manifest is stale — rerun with ${REGEN_ENV_VAR}=1 ` +
  "(yarn regen:registry-manifest in l1-contracts/test/anvil-interop) and commit the result " +
  `(${REGISTRY_MANIFEST_REL}).`;

// Sources compiled with the `registry-deterministic` forge profile (CBOR-metadata-free, so
// byte-identical across platforms; see foundry.toml). Everything a committed bytecode hash or
// bytecode-derived address covers is deployed from this build.
const DETERMINISTIC_FOUNDRY_PROFILE = "registry-deterministic";

// Mirrors BytecodePublisher.MAX_BATCH_SIZE: the byte budget of one `publishEVMBytecodes` call.
const MAX_PUBLISH_BATCH_BYTES = 126_000;
const PUBLISH_GAS_LIMIT = 15_000_000;
const DETERMINISTIC_SOURCES = [
  "contracts/state-transition/chain-deps/facets/Admin.sol",
  "contracts/state-transition/chain-deps/facets/Getters.sol",
  "contracts/state-transition/chain-deps/facets/Executor.sol",
  "contracts/state-transition/chain-deps/facets/Migrator.sol",
  "contracts/state-transition/chain-deps/facets/Committer.sol",
  "contracts/upgrades/DefaultUpgrade.sol",
  "contracts/state-transition/chain-deps/DiamondInit.sol",
  "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol",
  "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol",
  "contracts/core/message-root/L1MessageRoot.sol",
  "contracts/dev-contracts/MockContractDeployer.sol",
  "contracts/upgrades/registry/objects/CTMRelease.sol",
  "contracts/upgrades/registry/objects/CTMTransition.sol",
  "contracts/upgrades/registry/objects/CoreTransition.sol",
  "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol",
];

// Mirror L2GenesisForceDeploymentsHelper.generateRandomAddress: the delegate must be
// installed at the address committed by its descriptor, including in the Anvil stand-in.
function upgradeDelegateInfo(): { deployedBytecodeInfo: string; address: string } {
  const bytecode = getDeterministicBytecode("MockContractDeployer");
  const hash = ethers.utils.keccak256(bytecode);
  const deployedBytecodeInfo = ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint32", "bytes32"],
    [hash, ethers.utils.hexDataLength(bytecode), hash]
  );
  const addressHash = ethers.utils.keccak256(ethers.utils.hexConcat([ethers.constants.HashZero, deployedBytecodeInfo]));
  return { deployedBytecodeInfo, address: ethers.utils.getAddress(ethers.utils.hexDataSlice(addressHash, 12)) };
}

// AdminFacet.acceptAdmin() — used to locate the live AdminFacet on the chain diamonds.
const ACCEPT_ADMIN_FRAGMENT = "acceptAdmin";
// GettersFacet.getProtocolVersion() — the spot check that the Getters facet was re-pointed.
const GET_PROTOCOL_VERSION_SELECTOR = "0x33ce93fe";

const DEFAULT_GAS_LIMIT = 10_000_000;

// ── Public types ─────────────────────────────────────────────────────

export type RegistryUpgradeScenario = {
  label: string;
  /** chain-states/<stateVersion> to boot from — the current-genesis states (see chain-states/README.md). */
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
  let receipt: ethers.providers.TransactionReceipt;
  try {
    receipt = await tx.wait();
  } catch (error) {
    // ethers v5 throws CALL_EXCEPTION on status-0 receipts before we can inspect them.
    const failed = (error as { receipt?: ethers.providers.TransactionReceipt }).receipt;
    if (failed) {
      const trace = await traceFailedTx(provider, failed.transactionHash);
      throw new Error(`${label} reverted:\n${trace}`);
    }
    throw error;
  }
  if (receipt.status !== 1) {
    const trace = await traceFailedTx(provider, receipt.transactionHash);
    throw new Error(`${label} reverted:\n${trace}`);
  }
  return receipt;
}

/** Sends `send(contract)` from `contract`'s live `owner()`, impersonated. */
async function sendAsOwner(
  provider: ethers.providers.JsonRpcProvider,
  contract: ethers.Contract,
  send: (connected: ethers.Contract) => Promise<ethers.providers.TransactionResponse>,
  label: string
): Promise<ethers.providers.TransactionReceipt> {
  const owner: string = await contract.owner();
  return impersonateAndRun(provider, owner, (signer) => sendAndCheck(provider, send(contract.connect(signer)), label));
}

// ── Main entry point ─────────────────────────────────────────────────

export async function runRegistryDrivenUpgradeScenario(scenario: RegistryUpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const regenRegistries = process.env[REGEN_ENV_VAR] === "1";
  const freshDeploy = process.env[FRESH_DEPLOY_ENV_VAR] === "1";

  try {
    // ── 1. Boot the ecosystem ──
    let ecosystem: FullDeploymentResult;
    if (freshDeploy) {
      console.log(`\n── ${FRESH_DEPLOY_ENV_VAR}=1: deploying a fresh ecosystem ──`);
      // Cached test tokens in the run state would make the setup skip deploying them.
      runner.clearState();
      ecosystem = await runner.deployAndSetupWithWrappedZk(anvilManager);
    } else {
      const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
      if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
        throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
      }
      ecosystem = await runner.loadChainStates(anvilManager, stateDir);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = ecosystem;
    const upgradeChains = selectUpgradeChains(chainAddresses, chains.config, scenario.targetRoles);
    if (upgradeChains.length === 0) {
      throw new Error(`No chains matched roles ${scenario.targetRoles.join(", ")}`);
    }
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }
    const l1Provider = createProvider(l1Chain.rpcUrl);
    const deployer = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    const l1ChainId = (await l1Provider.getNetwork()).chainId;

    // ── 2. Read the live upgrade inputs and the executors the deployment created ──
    console.log("\n── Reading live ecosystem state ──");
    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
    const live = await readLiveUpgradeInputs(l1Provider, ctm, upgradeChains, l1Addresses.messageRoot);
    console.log(`  old protocol version: ${live.oldVersionString} (${live.oldVersion.toString()})`);
    console.log(`  new protocol version: ${live.newVersionString} (${live.newVersion.toString()})`);
    console.log(`  current release: ${live.fromRelease}`);
    console.log(`  live AdminFacet: ${live.oldAdminFacet} (${live.adminSelectors.length} selectors)`);

    console.log("\n── Discovering the upgrade executors ──");
    const executors = await discoverUpgradeExecutors(l1Provider, ctm.address, live);
    const ctmExecutor = new ethers.Contract(executors.ctmExecutor, getAbi("CTMUpgradeExecutor"), l1Provider);
    const coreExecutor = new ethers.Contract(executors.coreExecutor, getAbi("CoreUpgradeExecutor"), l1Provider);
    const coordinator = new ethers.Contract(executors.coordinator, getAbi("EcosystemUpgradeExecutor"), l1Provider);

    // ── 3. Deploy the new-version implementations ──
    console.log("\n── Deploying new-version implementations ──");
    buildDeterministicArtifacts();
    const deployed = await deployUpgradeImplementations(deployer, {
      l1ChainId,
      rollupDAManager: live.rollupDAManager,
      bridgehub: l1Addresses.bridgehub,
      chainAssetHandler: live.chainAssetHandler,
    });

    // ── 4. Regenerate (EMIT) or validate (CONSUME) the committed manifest, then deploy the
    //       release / core transition / CTM transition from it ──
    const manifestPath = path.join(l1ContractsDir, REGISTRY_MANIFEST_REL);
    if (regenRegistries) {
      console.log(`\n── ${REGEN_ENV_VAR}=1: regenerating the committed registry manifest ──`);
      const manifest = buildRegistryManifest(live, deployed, ctmAddresses.chainTypeManager);
      fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
      fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
      console.log(`  manifest written to ${REGISTRY_MANIFEST_REL}`);
    } else {
      console.log(`\n── Consuming the committed registry manifest (${REGISTRY_MANIFEST_REL}) ──`);
      assertCommittedManifestMatchesLiveDeployment(manifestPath, live, deployed, ctmAddresses.chainTypeManager);
    }
    const manifestJson = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
    const objects = await deployUpgradeObjectsFromManifest(deployer, manifestJson, deployed, executors.coordinator);
    console.log(`  CTM release:     ${objects.release}`);
    console.log(`  CTM transition:  ${objects.transition}`);
    console.log(`  core transition: ${objects.coreTransition}`);

    // `validate()` is what the executors call on the execution path; running it here makes a
    // manifest naming an address without code fail in this step rather than mid-upgrade.
    const releaseContract = new ethers.Contract(objects.release, getAbi("ICTMRelease"), l1Provider);
    const transition = new ethers.Contract(objects.transition, getAbi("ICTMTransition"), l1Provider);
    const coreTransitionContract = new ethers.Contract(objects.coreTransition, getAbi("ICoreTransition"), l1Provider);
    try {
      await releaseContract.callStatic.validate();
      await transition.callStatic.validate();
      await coreTransitionContract.callStatic.validate();
      assertEq(await transition.fromRelease(), live.fromRelease, "transition departs from the CTM's live release");
      assertEq(
        (await transition.newProtocolVersion()).toString(),
        live.newVersion.toString(),
        "transition commits the new protocol version"
      );
      assertTrue((await coreTransitionContract.ecosystemRows()).length > 0, "core transition has ecosystem rows");
    } catch (error) {
      throw regenRegistries ? error : staleRegistriesError(error);
    }

    // The CTM leg refuses to commit an edge whose L2 factory dependencies are not published.
    const supplier = new ethers.Contract(await ctm.L1_BYTECODES_SUPPLIER(), getAbi("BytecodesSupplier"), deployer);
    await publishFactoryDeps(l1Provider, supplier, [getDeterministicBytecode("MockContractDeployer")]);
    console.log("  ✓ the L2 delegate's bytecode is published on the CTM's supplier");

    // ── 5. Execute the operation through the coordinator ──
    console.log("\n── Executing the registry-driven upgrade via the coordinator ──");
    const cah = new ethers.Contract(live.chainAssetHandler, getAbi("L1ChainAssetHandler"), l1Provider);
    const operationFactory = new ethers.ContractFactory(
      getAbi("EcosystemUpgradeOperation"),
      getDeterministicCreationBytecode("EcosystemUpgradeOperation"),
      deployer
    );
    const operationContract = await operationFactory.deploy(
      operationInitArgs(
        (manifestJson.ctms || []).find((c: { name?: string }) => c.name === CTM_REGISTRY_NAME),
        objects.coreTransition,
        objects.transition,
        objects.upgradeTimer
      )
    );
    await operationContract.deployed();
    const operation: string = operationContract.address;
    console.log(`  operation: ${operation}`);

    await sendAsOwner(
      l1Provider,
      coordinator,
      (c) => c.stage0(operation, { gasLimit: DEFAULT_GAS_LIMIT }),
      "coordinator.stage0(operation)"
    );
    assertTrue(await cah.migrationPausedFor(ctm.address), "stage 0 leaves THIS CTM's migrations paused");
    assertEq(await ctmExecutor.reservedTransition(), objects.transition, "stage 0 reserved the CTM executor");
    assertEq(
      await coordinator.pendingManifestHash(),
      await operationContract.manifestHash(),
      "stage 0 pinned the operation's manifest hash"
    );
    await sendAsOwner(
      l1Provider,
      coordinator,
      (c) => c.stage1(operation, { gasLimit: DEFAULT_GAS_LIMIT }),
      "coordinator.stage1(operation)"
    );
    console.log("  ✓ stage1 executed (ecosystem rows, CTM leg, version commit, release pin)");

    // The chains' genesis upgrade tx is still pending on the sequencer-less anvil chains (see
    // module docs); cleared once, before the first bump.
    await clearGenesisUpgradeTxHash(l1Provider, upgradeChains);
    for (const chain of upgradeChains) {
      await sendAsOwner(
        l1Provider,
        ctmExecutor,
        (c) => c.upgradeChain(objects.transition, chain.chainId, { gasLimit: DEFAULT_GAS_LIMIT }),
        `ctmExecutor.upgradeChain(transition) for chain ${chain.chainId}`
      );
      console.log(`  ✓ chain ${chain.chainId} upgraded`);
    }

    await sendAsOwner(
      l1Provider,
      coordinator,
      (c) => c.stage2(operation, { gasLimit: DEFAULT_GAS_LIMIT }),
      "coordinator.stage2(operation)"
    );
    assertTrue(!(await cah.migrationPausedFor(ctm.address)), "stage 2 unpaused this CTM's migrations");
    assertEq(await coordinator.pendingOperation(), ethers.constants.AddressZero, "stage 2 cleared the lifecycle slot");
    assertEq(await coordinator.pendingManifestHash(), ethers.constants.HashZero, "stage 2 cleared the pinned hash");
    assertEq(await ctmExecutor.activeOperation(), ethers.constants.AddressZero, "stage 2 released the CTM reservation");
    assertEq(
      await coreExecutor.activeOperation(),
      ethers.constants.AddressZero,
      "stage 2 released the core reservation"
    );

    // ── 6. L1 end state ──
    console.log("\n── Verifying L1 end state ──");
    // The transition serves each chain's L2 transaction (it forwards to the pinned engine); its
    // hash is what `BaseZkSyncUpgrade` stores on each chain diamond.
    const l2TxParamType = transition.interface.getFunction("l2UpgradeTx").outputs?.[0];
    if (!l2TxParamType) {
      throw new Error("ICTMTransition ABI has no l2UpgradeTx output");
    }
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
    assertEq(
      await ctm.upgradeTransition(live.oldVersion),
      objects.transition,
      "CTM transition committed for the departing version"
    );
    assertEq(
      await ctm.upgradeCutHash(live.oldVersion),
      ethers.constants.HashZero,
      "deprecated upgradeCutHash stays untouched on the transition path"
    );
    assertEq(
      (await ctm.protocolVersionDeadline(live.oldVersion)).toString(),
      ethers.constants.MaxUint256.toString(),
      "departing version's deadline resolves through the committed transition"
    );
    const pinnedRelease = new ethers.Contract(await ctm.currentRelease(), getAbi("ICTMRelease"), l1Provider);
    assertEq(await pinnedRelease.verifier(), deployed.newVerifier, "the pinned release carries the fresh verifier");
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
      assertEq(
        await diamond.facetAddress(GET_PROTOCOL_VERSION_SELECTOR),
        deployed.newGettersFacet,
        `chain ${chain.chainId}: GettersFacet re-pointed to the fresh implementation`
      );
      assertEq(
        await diamond.getVerifier(),
        deployed.newVerifier,
        `chain ${chain.chainId}: verifier switched to the fresh instance`
      );
      const composedTx = await transition.l2UpgradeTx(l1Addresses.bridgehub, chain.chainId);
      const expectedL2TxHash = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode([l2TxParamType], [composedTx])
      );
      assertEq(
        await diamond.getL2SystemContractsUpgradeTxHash(),
        expectedL2TxHash,
        `chain ${chain.chainId}: committed L2 upgrade tx hash equals the transaction the transition composes for it`
      );
    }
    const implSlot = await l1Provider.getStorageAt(l1Addresses.messageRoot, EIP1967_IMPL_SLOT);
    assertEq(
      ethers.utils.getAddress("0x" + implSlot.slice(26)),
      deployed.newMessageRootImpl,
      "MessageRoot proxy re-pointed to the fresh implementation by CoreUpgradeExecutor"
    );

    // ── 7. Relay each chain's composed L2 upgrade tx to its L2 chain ──
    console.log("\n── Relaying the transition-composed L2 upgrade transaction ──");
    for (const chain of upgradeChains) {
      const composedTx = await transition.l2UpgradeTx(l1Addresses.bridgehub, chain.chainId);
      const l2Chain = anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
      if (!l2Chain) {
        throw new Error(`Missing running L2 chain ${chain.chainId}`);
      }
      await relayL2UpgradeTx(createProvider(l2Chain.rpcUrl), composedTx.data, chain.chainId);
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
  /** The CTM proxy's own ProxyAdmin — the one the CTM executor is bound to. */
  ctmProxyAdmin: string;
  /** The CTM's live `currentRelease` — the transition's `fromRelease`. */
  fromRelease: string;
  oldAdminFacet: string;
  adminSelectors: string[];
  otherFacets: { name: string; address: string }[];
  acceptAdminSelector: string;
  genesisUpgrade: string;
  rollupDAManager: string;
  chainAssetHandler: string;
  /** The ecosystem ProxyAdmin (read off the MessageRoot proxy) — the one the core executor is bound to. */
  ecosystemProxyAdmin: string;
  messageRootProxy: string;
  /** The proxy's live (pre-upgrade) implementation — the source side of the ecosystem edge. */
  messageRootImplOld: string;
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
  // One synthetic minor edge V -> V+1 (the "v35 -> v36" model).
  const newVersion = oldVersion.div(minorShift).add(1).mul(minorShift);

  const fromRelease: string = await ctm.currentRelease();
  if (fromRelease === ethers.constants.AddressZero) {
    throw new Error("live CTM has no currentRelease — regenerate the chain states from registry-era code");
  }

  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
  const acceptAdminSelector = adminIface.getSighash(ACCEPT_ADMIN_FRAGMENT);

  // Locate the live AdminFacet (address + installed selectors) on the first target chain and
  // check that every target chain shares it — the release names ONE facet set.
  const firstDiamond = new ethers.Contract(upgradeChains[0].diamondProxy, getAbi("GettersFacet"), l1Provider);
  const oldAdminFacet: string = await firstDiamond.facetAddress(acceptAdminSelector);
  const adminSelectors: string[] = await firstDiamond.facetFunctionSelectors(oldAdminFacet);

  // Locate the remaining live facets by probing one representative selector each, so the
  // release names (and validate() covers) the complete facet surface, not only the facets
  // this synthetic bump replaces.
  const facetProbes: { name: string; selector: string }[] = [
    { name: "GettersFacet", selector: GET_PROTOCOL_VERSION_SELECTOR },
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

  const adminFacetView = new ethers.Contract(upgradeChains[0].diamondProxy, getAbi("AdminFacet"), l1Provider);
  const rollupDAManager: string = await adminFacetView.getRollupDAManager();

  const genesisUpgrade: string = await ctm.l1GenesisUpgrade();

  const bridgehubAddr: string = await ctm.BRIDGE_HUB();
  const bridgehub = new ethers.Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Provider);
  const chainAssetHandler: string = await bridgehub.chainAssetHandler();

  const readAddressSlot = async (account: string, slot: string) =>
    ethers.utils.getAddress("0x" + (await l1Provider.getStorageAt(account, slot)).slice(26));

  const toVersionString = (v: ethers.BigNumber) => `0.${v.div(minorShift).toString()}.0`;
  return {
    oldVersion,
    newVersion,
    oldVersionString: toVersionString(oldVersion),
    newVersionString: toVersionString(newVersion),
    ctmProxyAdmin: await readAddressSlot(ctm.address, EIP1967_ADMIN_SLOT),
    fromRelease,
    oldAdminFacet,
    adminSelectors,
    otherFacets,
    acceptAdminSelector,
    genesisUpgrade,
    rollupDAManager,
    chainAssetHandler,
    ecosystemProxyAdmin: await readAddressSlot(messageRootProxy, EIP1967_ADMIN_SLOT),
    messageRootProxy,
    messageRootImplOld: await readAddressSlot(messageRootProxy, EIP1967_IMPL_SLOT),
  };
}

type UpgradeExecutors = { ctmExecutor: string; coordinator: string; coreExecutor: string };

/**
 * The executors the deployment created, read from chain (CTM owner -> its `coordinator()` -> the
 * coordinator's `CORE_EXECUTOR()`), asserted to be in the bound shape a fresh ecosystem is born
 * with: every binding both ways, the CTM, its ProxyAdmin and the ServerNotifier held by the CTM
 * executor, the ecosystem ProxyAdmin by the core executor, and one owner over all three executors.
 */
async function discoverUpgradeExecutors(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  live: LiveUpgradeInputs
): Promise<UpgradeExecutors> {
  const ctmOwnable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const ctmExecutorAddr: string = await ctmOwnable.owner();
  assertTrue((await l1Provider.getCode(ctmExecutorAddr)) !== "0x", `CTM owner ${ctmExecutorAddr} is a contract`);
  assertEq(await ctmOwnable.pendingOwner(), ethers.constants.AddressZero, "CTM has no pending owner");

  const ctmExecutor = new ethers.Contract(ctmExecutorAddr, getAbi("CTMUpgradeExecutor"), l1Provider);
  assertEq(await ctmExecutor.CHAIN_TYPE_MANAGER(), ctmAddr, "CTM executor is bound to the CTM");
  assertEq(await ctmExecutor.CTM_PROXY_ADMIN(), live.ctmProxyAdmin, "CTM executor is bound to the CTM's ProxyAdmin");
  const ctmProxyAdmin = new ethers.Contract(live.ctmProxyAdmin, getAbi("ProxyAdmin"), l1Provider);
  assertEq(await ctmProxyAdmin.owner(), ctmExecutorAddr, "CTM-domain ProxyAdmin owned by the CTM executor");
  await assertServerNotifierState(
    l1Provider,
    ctmAddr,
    {
      admin: live.ctmProxyAdmin,
      owner: ctmExecutorAddr,
      pendingOwner: ethers.constants.AddressZero,
      chainTypeManager: ctmAddr,
    },
    "held by the CTM executor under the CTM-domain ProxyAdmin"
  );

  const coordinatorAddr: string = await ctmExecutor.coordinator();
  const coordinator = new ethers.Contract(coordinatorAddr, getAbi("EcosystemUpgradeExecutor"), l1Provider);
  assertEq(await coordinator.ctmExecutor(), ctmExecutorAddr, "coordinator is bound to the CTM executor");
  const coreExecutorAddr: string = await coordinator.CORE_EXECUTOR();
  const coreExecutor = new ethers.Contract(coreExecutorAddr, getAbi("CoreUpgradeExecutor"), l1Provider);
  assertEq(await coreExecutor.coordinator(), coordinatorAddr, "core executor answers to the coordinator");
  assertEq(
    await coreExecutor.PROXY_ADMIN(),
    live.ecosystemProxyAdmin,
    "core executor is bound to the ecosystem ProxyAdmin"
  );
  const ecosystemProxyAdmin = new ethers.Contract(live.ecosystemProxyAdmin, getAbi("ProxyAdmin"), l1Provider);
  assertEq(await ecosystemProxyAdmin.owner(), coreExecutorAddr, "ecosystem ProxyAdmin owned by the core executor");

  // Governance on a production ecosystem; on a fresh anvil deployment the deployer, with
  // governance's nomination never accepted.
  const owner: string = await coordinator.owner();
  const pendingOwner: string = await coordinator.pendingOwner();
  for (const executor of [ctmExecutor, coreExecutor]) {
    assertEq(await executor.owner(), owner, `executor ${executor.address} shares the coordinator's owner`);
    assertEq(await executor.pendingOwner(), pendingOwner, `executor ${executor.address} shares its pending owner`);
  }
  console.log(`  CTM executor:  ${ctmExecutorAddr}`);
  console.log(`  coordinator:   ${coordinatorAddr}`);
  console.log(`  core executor: ${coreExecutorAddr}`);
  console.log(`  owner: ${owner} (pending: ${pendingOwner})`);
  return { ctmExecutor: ctmExecutorAddr, coordinator: coordinatorAddr, coreExecutor: coreExecutorAddr };
}

// ── Deployment ───────────────────────────────────────────────────────

type DeployedImplementations = {
  /** The harness's fixed no-op delegate-calldata composer, pinned by the transition's L2 plan. */
  delegateComposer: string;
  newAdminFacet: string;
  newGettersFacet: string;
  newExecutorFacet: string;
  newMigratorFacet: string;
  newCommitterFacet: string;
  newDefaultUpgrade: string;
  newDiamondInit: string;
  newVerifierPlonk: string;
  newVerifier: string;
  newMessageRootImpl: string;
};

async function deployUpgradeImplementations(
  deployer: ethers.Wallet,
  params: {
    l1ChainId: number;
    rollupDAManager: string;
    bridgehub: string;
    chainAssetHandler: string;
  }
): Promise<DeployedImplementations> {
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
  // Deployed from the deterministic (CBOR-metadata-free) build, the one the committed manifest's
  // bytecode-DERIVED values are taken from — see buildDeterministicArtifacts().
  const deployDeterministic = (name: Parameters<typeof getAbi>[0], args: unknown[]) =>
    deployFrom(name, getDeterministicCreationBytecode(name), args);
  const mockDeployer = getDeterministicBytecode("MockContractDeployer");

  // NOTE: the deploy ORDER below is part of the committed manifest's contract: the deployer key and
  // starting nonce are fixed by the chain states, so each contract's address is a pure function of
  // its position in this sequence. Reordering/inserting deploys invalidates the committed manifest
  // (rerun with REGEN_REGISTRIES=1).
  const newVerifierPlonk = await deployDeterministic("ZKsyncOSVerifierPlonk", []);
  return {
    // Pinned CODE defines the delegate calldata. The mock delegate deliberately has no fallback,
    // so the composed call names its explicit no-op method and a stale selector still fails.
    delegateComposer: await deployFrom(
      "FixedDelegateCalldataComposer",
      getCreationBytecode("FixedDelegateCalldataComposer"),
      [
        new ethers.utils.Interface(getAbi("MockContractDeployer")).encodeFunctionData("setBytecodeDetailsEVM", [
          upgradeDelegateInfo().address,
          ethers.utils.keccak256(mockDeployer),
          ethers.utils.hexDataLength(mockDeployer),
          ethers.utils.keccak256(mockDeployer),
        ]),
      ]
    ),
    // The synthetic bump's facet set, constructed like the live deployment (l1ChainId, the live
    // RollupDAManager, testnet). MailboxFacet is the one facet NOT replaced: its constructor needs
    // the live EIP7702Checker, which only the original deployment config knows, so the release
    // keeps the live Mailbox.
    newAdminFacet: await deployDeterministic("AdminFacet", [params.l1ChainId, params.rollupDAManager]),
    newGettersFacet: await deployDeterministic("GettersFacet", []),
    newExecutorFacet: await deployDeterministic("ExecutorFacet", []),
    newMigratorFacet: await deployDeterministic("MigratorFacet", [params.l1ChainId, true /* _isTestnet */]),
    newCommitterFacet: await deployDeterministic("CommitterFacet", [params.l1ChainId]),
    newDefaultUpgrade: await deployDeterministic("DefaultUpgrade", []),
    newDiamondInit: await deployDeterministic("DiamondInit", []),
    // The ZKsync OS testnet verifier over the plonk sub-verifier deployed above; no proofs are
    // verified in this harness.
    newVerifierPlonk,
    newVerifier: await deployDeterministic("ZKsyncOSTestnetVerifier", [newVerifierPlonk]),
    // Ecosystem leg: a fresh L1MessageRoot implementation with the live immutable values.
    newMessageRootImpl: await deployDeterministic("L1MessageRoot", [params.bridgehub, params.chainAssetHandler]),
  };
}

/**
 * Publishes `bytecodes` on the CTM's supplier (skipping ones already there), batched by the
 * publisher's byte budget.
 */
async function publishFactoryDeps(
  l1Provider: ethers.providers.JsonRpcProvider,
  supplier: ethers.Contract,
  bytecodes: string[]
): Promise<void> {
  let batch: string[] = [];
  let batchBytes = 0;
  const flush = async () => {
    if (batch.length === 0) {
      return;
    }
    await sendAndCheck(
      l1Provider,
      supplier.publishEVMBytecodes(batch, { gasLimit: PUBLISH_GAS_LIMIT }),
      `BytecodesSupplier.publishEVMBytecodes(${batch.length} bytecodes)`
    );
    batch = [];
    batchBytes = 0;
  };
  for (const bytecode of bytecodes) {
    const publishedAt: ethers.BigNumber = await supplier.evmPublishingBlock(ethers.utils.keccak256(bytecode));
    if (!publishedAt.isZero()) {
      continue;
    }
    const size = ethers.utils.hexDataLength(bytecode);
    if (batchBytes + size > MAX_PUBLISH_BATCH_BYTES) {
      await flush();
    }
    batch.push(bytecode);
    batchBytes += size;
  }
  await flush();
}

// ── Manifest generation ──────────────────────────────────────────────

function buildRegistryManifest(
  live: LiveUpgradeInputs,
  deployed: DeployedImplementations,
  ctmProxy: string
): Record<string, unknown> {
  // The L2 leg of the synthetic bump: the (no-op) L2 upgrade implementation's bytecode info. The
  // transition constructs its Unsafe deployment at the bytecode-derived address and delegatecalls
  // it — the exact shape of a production ZKsyncOS upgrade transaction.
  const { deployedBytecodeInfo } = upgradeDelegateInfo();

  // Production freezability flags (DeployCTMUtils facet cuts).
  const freezability: Record<string, boolean> = {
    AdminFacet: false,
    GettersFacet: false,
    MailboxFacet: true,
    ExecutorFacet: true,
    MigratorFacet: false,
    CommitterFacet: true,
  };

  // The release's complete facet surface; the transition DERIVES its delta on-chain from
  // (fromRelease, newRelease). MailboxFacet keeps its live address, so the delta has no row for it.
  const installedFacets = [
    { name: "AdminFacet", address: deployed.newAdminFacet },
    { name: "GettersFacet", address: deployed.newGettersFacet },
    { name: "ExecutorFacet", address: deployed.newExecutorFacet },
    { name: "MigratorFacet", address: deployed.newMigratorFacet },
    { name: "CommitterFacet", address: deployed.newCommitterFacet },
    { name: "MailboxFacet", address: liveFacet(live, "MailboxFacet") },
  ];
  const genesisFacets = installedFacets.map(({ name, address }) => ({
    name,
    address,
    isFreezable: freezability[name],
  }));

  return {
    tag: REGISTRY_TAG,
    oldVersion: live.oldVersionString,
    newVersion: live.newVersionString,
    core: {
      // Source-checked rows keyed by `L1EcosystemContract` member name; every omitted slot encodes
      // as the explicit "not upgraded" zero row.
      contracts: {
        L1MessageRoot: {
          proxy: live.messageRootProxy,
          expectedOldImpl: live.messageRootImplOld,
          implNew: deployed.newMessageRootImpl,
        },
      },
    },
    ctms: [
      {
        name: CTM_REGISTRY_NAME,
        isZKsyncOS: true,
        ctmProxy,
        release: {
          diamondInit: { address: deployed.newDiamondInit },
          verifier: { address: deployed.newVerifier },
          genesisFacets,
          // No chain is created at this release here, so a synthetic payload consistent with the
          // empty L2 table below suffices.
          fixedForceDeploymentsData: emptyTableForceDeploymentsData(),
          // Keys are `L2EcosystemContract` member names; empty = every slot an explicit empty row,
          // so the transition derives no L2 table deployments, and an empty table names no shell.
          l2BytecodeInfos: {},
          l2SystemProxyBytecodeInfo: "0x",
          genesis: {
            genesisUpgrade: { address: live.genesisUpgrade },
            batchHash: ethers.utils.hexZeroPad("0x01", 32),
            indexRepeatedStorageChanges: 54,
          },
        },
        transition: {
          fromRelease: live.fromRelease,
          upgradeEngine: { address: deployed.newDefaultUpgrade },
          // Schedule: immediately executable, old version stays usable indefinitely.
          oldProtocolVersionDeadline: ethers.constants.MaxUint256.toHexString(),
          upgradeTimestamp: 0,
          l2Plan: {
            delegateBytecodeInfo: deployedBytecodeInfo,
            extraBytecodeInfos: [],
          },
        },
      },
    ],
  };
}

/**
 * Compile the pinned sources with the `registry-deterministic` forge profile into
 * out-registry-deterministic/. Both modes run this: emit records the resulting addresses and
 * bytecode-derived values, consume deploys the exact same bytecode so those committed values still
 * describe this run.
 */
function buildDeterministicArtifacts(): void {
  console.log(`  compiling pinned sources with FOUNDRY_PROFILE=${DETERMINISTIC_FOUNDRY_PROFILE}…`);
  const result = spawnSync("forge", ["build", ...DETERMINISTIC_SOURCES], {
    cwd: l1ContractsDir,
    stdio: "inherit",
    env: { ...process.env, FOUNDRY_PROFILE: DETERMINISTIC_FOUNDRY_PROFILE },
  });
  if (result.status !== 0) {
    throw new Error(`forge build failed for the ${DETERMINISTIC_FOUNDRY_PROFILE} profile (status ${result.status})`);
  }
}

function staleRegistriesError(cause: unknown): Error {
  const message = cause instanceof Error ? cause.message : String(cause);
  return new Error(`${message}\n\n${STALE_REGISTRIES_HINT}`);
}

/**
 * CONSUME mode gate: the committed manifest must describe exactly the live deployment this run
 * produced — same protocol versions, same live addresses from the chain states, and the same
 * nonce-deterministic freshly deployed implementation addresses.
 */
function assertCommittedManifestMatchesLiveDeployment(
  manifestPath: string,
  live: LiveUpgradeInputs,
  deployed: DeployedImplementations,
  ctmProxy: string
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
    // A fresh ecosystem is born into the registry model: the manifest describes no bootstrap.
    ["bootstrap (absent)", manifest.bootstrap === undefined && manifest.bootstrapVersion === undefined, true],
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
    ["ctm.release.verifier.address", ctm?.release?.verifier?.address, deployed.newVerifier],
    ["ctm.transition.upgradeEngine.address", ctm?.transition?.upgradeEngine?.address, deployed.newDefaultUpgrade],
    // No facet swaps in the manifest at all: the delta is DERIVED on-chain from the release pair.
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
 * Deploy the release / core transition / CTM transition from the manifest — each takes its manifest
 * as a constructor argument. The release deploys first: the transition's constructor validates its
 * target release and derives the facet/L2 delta from the release pair. The operation's timer is
 * bound to the coordinator (only it can start it); zero delays make the stage-1 window pass
 * immediately, and the deployer keeps the (unused) extension right.
 */
async function deployUpgradeObjectsFromManifest(
  deployer: ethers.Wallet,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  manifest: any,
  deployed: DeployedImplementations,
  coordinator: string
): Promise<{ release: string; transition: string; coreTransition: string; upgradeTimer: string }> {
  const ctm = (manifest.ctms || []).find((c: { name?: string }) => c.name === CTM_REGISTRY_NAME);
  if (!ctm) {
    throw new Error(`manifest has no "${CTM_REGISTRY_NAME}" CTM entry`);
  }

  const deployObject = async (
    name: "CTMRelease" | "CTMTransition" | "CoreTransition",
    manifestArg: unknown
  ): Promise<string> => {
    const factory = new ethers.ContractFactory(getAbi(name), getDeterministicCreationBytecode(name), deployer);
    const contract = await factory.deploy(manifestArg);
    await contract.deployed();
    return contract.address;
  };

  const release = await deployObject("CTMRelease", releaseInitArgs(manifest, ctm));
  const coreTransition = await deployObject("CoreTransition", coreInitArgs(manifest));
  const timerFactory = new ethers.ContractFactory(
    getAbi("GovernanceUpgradeTimer"),
    getCreationBytecode("GovernanceUpgradeTimer"),
    deployer
  );
  const upgradeTimer = await timerFactory.deploy(0, 0, coordinator, deployer.address);
  await upgradeTimer.deployed();
  return {
    release,
    transition: await deployObject(
      "CTMTransition",
      transitionInitArgs(manifest, ctm, release, deployed.delegateComposer)
    ),
    coreTransition,
    upgradeTimer: upgradeTimer.address,
  };
}

// ── L2 relay ─────────────────────────────────────────────────────────

/**
 * Relay the transition-composed L2 upgrade transaction to an L2 anvil chain through the real
 * `L2ComplexUpgrader`, after placing the no-op delegate at its derived address (see module docs).
 * The transaction data itself is the UNCHANGED composed calldata.
 */
async function relayL2UpgradeTx(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string,
  chainId: number
): Promise<void> {
  await l2Provider.send("anvil_setCode", [
    upgradeDelegateInfo().address,
    getDeterministicBytecode("MockContractDeployer"),
  ]);

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
