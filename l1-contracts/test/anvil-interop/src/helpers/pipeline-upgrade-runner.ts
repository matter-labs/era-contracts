/**
 * Version-independent pipeline upgrade test runner.
 *
 * Successor of the deleted v31 runner: replays a REAL protocol upgrade — the production
 * protocol-ops toolchain driving the version's actual forge prepare scripts — against
 * pre-generated anvil chain states of the departing version:
 *
 *   1. Load the frozen chain states (`chain-states/<stateVersion>`) and select target chains.
 *   2. Normalize L1 ownership (fixtures leave contracts with the deployer; governance needs them).
 *   3. (Only when the scenario asks for it) install the pre-v35 cut-taking entrypoint
 *      (`LegacyTestAdminFacet`) on the target chains. A fixture frozen from a branch whose
 *      Admin facet already READS its cut from the CTM needs the shim; the current frozen
 *      fixture carries the real cut-taking facet, so the chains cross natively — exactly like
 *      production pre-v35 chains.
 *   4. `protocol-ops ecosystem upgrade-prepare-all` with the scenario's core/CTM script paths
 *      (deployer Safe bundles replayed onto the harness anvil, the ChainAdmin's half of the one-time
 *      ServerNotifier handover included); the merged governance bundle is asserted to be exactly
 *      the one `RegistryBootstrapSequence.actions()` derives, closing with the edge's completion
 *      check; `protocol-ops ecosystem verify-bootstrap` must pass on the package (see
 *      `verifyPackageAsReviewed`). Then `protocol-ops ecosystem upgrade-governance` replays that
 *      one bundle.
 *   5. Per-chain legacy handed-cut crossing, recorded-L2-tx verification, and the L2 relay of
 *      the proposed upgrade transaction on each chain's anvil fork.
 *   6. Final protocol-version verification on every upgraded chain.
 *
 * Everything version-specific rides the scenario: the departing state, the prepare scripts, the
 * upgrade-input/permanent-values templates and the expected final version.
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETHEREUM_L1_TX_GAS_LIMIT,
  EIP1967_ADMIN_SLOT,
  EIP1967_IMPL_SLOT,
  ETH_TOKEN_ADDRESS,
  INITIAL_BASE_TOKEN_HOLDER_BALANCE,
  INTEROP_ATTRIBUTE_PARSER_ADDR,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_BASE_TOKEN_HOLDER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  L2_CONTRACT_DEPLOYER_ADDR,
  L2_FORCE_DEPLOYER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_REMOVED_GW_ASSET_TRACKER_ADDR,
  L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
  L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
  NTV_WETH_TOKEN_SLOT,
  NTV_L1_CHAIN_ID_SLOT,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";
import type { ContractName } from "../core/contracts";
import { forceBatchExecutedEqualsCommitted, transferOwnable2Step } from "./harness-shims";
import {
  clearGenesisUpgradeTxHash,
  readProxyAdmin,
  readProxyImplementation,
  selectUpgradeChains,
  traceFailedTx,
} from "./upgrade-test-utils";
import {
  assertBootstrapBundle,
  assertBootstrapCompleted,
  assertServerNotifierState,
  installLegacyFacet,
  crossBootstrapEdgeOnChains,
} from "./bootstrap-upgrade-stage";
import type { MergedGovernanceOutput } from "./governance-bundle";
import { assertRegistryHopBundle } from "./governance-bundle";
import { recordL1TransactionGas } from "./l1-transaction-gas";
import { proxyUpgradeSlotIndex } from "./registry-manifest";
import { createProvider, impersonateAndRun } from "../core/utils";
import { runtimeConfig } from "../core/runtime-config";
import type { ChainRole } from "../core/types";

// ── Constants ────────────────────────────────────────────────────────

// ContractUpgradeType enum values from IComplexUpgrader.sol
const UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT = 0;
const UPGRADE_TYPE_ZKOS_SYSTEM_PROXY = 1;
const UPGRADE_TYPE_ZKOS_UNSAFE_FORCE_DEPLOY = 2;

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");
const contractsRootDir = path.resolve(l1ContractsDir, "..");

// Function selectors for the ComplexUpgrader entry points.
const SELECTORS = {
  // forceDeployAndUpgrade((bytes32,address,bool,uint256,bytes)[],address,bytes) — Era
  eraForceDeployAndUpgrade: "0x480d1185",
  // forceDeployAndUpgradeUniversal((uint8,bytes,address)[],address,bytes) — ZKsyncOS
  zkosForceDeployAndUpgradeUniversal: "0xd8cfca80",
} as const;

// ── Public types ─────────────────────────────────────────────────────

export type PipelineUpgradeScenario = {
  label: string;
  /** chain-states/<stateVersion> to boot from — the FROZEN departing-version fixture. */
  stateVersion: string;
  permanentValuesTemplatePath: string;
  upgradeInputTemplatePath: string;
  isZKsyncOS: boolean;
  targetRoles: ChainRole[];
  /** Protocol version the chains must report once the upgrade has been applied. */
  expectedProtocolVersion: string;
  /**
   * Forge script targets driven by protocol-ops (`--core-script-path` / `--ctm-script-path`). Omitted,
   * protocol-ops prepares with its defaults: the current release's scripts.
   */
  coreScriptPath?: string;
  ctmScriptPath?: string;
  /**
   * Bytecode placed at the L2 upgrade transaction's decoded delegate target before the relay
   * (the anvil L2s cannot force-deploy, so the harness `anvil_setCode`s it).
   */
  l2DelegateBytecodeName: ContractName;
  clearGenesisUpgradeTxHash?: boolean;
  /**
   * Install `LegacyTestAdminFacet` before governance. Needed ONLY for fixtures whose Admin
   * facet is the cut-READING (v35+) variant; a fixture with the real pre-v35 cut-taking facet
   * crosses natively, and installing the shim there collides (`FacetExists`).
   */
  installLegacyCutTakingFacet?: boolean;
  /**
   * A REGISTRY-DRIVEN hop run on the same chains right after this scenario: the base prepare
   * pipeline deploys a fresh release + `CTMTransition`, governance executes exactly one
   * `EcosystemUpgradeExecutor.execute(operation)` call, and every chain crosses through the
   * cut-READING `upgradeChainFromVersion` (see runRecurringHop).
   */
  followUps?: RecurringUpgradeHop[];
};

export type RecurringUpgradeHop = {
  label: string;
  upgradeInputTemplatePath: string;
  /** Protocol version the chains must report once the hop has been applied. */
  expectedProtocolVersion: string;
  coreScriptPath: string;
  ctmScriptPath: string;
  /**
   * Assert that the prepare REUSED every live release member. Set it for a hop that changes no CTM
   * release member: the prepare then publishes a copy of the live release one version up — one
   * release per version — so the transition's `releaseDiff()` names nothing and the derived facet
   * delta is empty: no chain sees facet churn for an upgrade that changed no facet.
   */
  expectsReusedReleaseMembers?: boolean;
  /**
   * Assert an empty derived facet delta while allowing a NEW release. Set it for a hop that
   * replaces a non-facet release member (a verifier): the routing is identical on both edges, so
   * the transition must not remove and re-add every selector onto the same facets.
   */
  expectsEmptyFacetDelta?: boolean;
  /**
   * Run this hop with the previous upgrade's L2 transaction still PENDING, and assert it survives
   * untouched. Only a patch edge may do this: `BaseZkSyncUpgrade` deliberately skips the
   * "previous upgrade finalized" check when the minor version does not change. Every other hop
   * has the pending hash cleared first, since these sequencer-less chains never finalize it.
   */
  keepsPendingL2Upgrade?: boolean;
  /** Assert this hop re-pointed the MessageRoot proxy at a freshly deployed implementation. */
  expectsFreshMessageRoot?: boolean;
};

// ── Main entry point ─────────────────────────────────────────────────

export async function runPipelineUpgradeScenario(scenario: PipelineUpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  let cleanupUpgradeHarnessInputs: (() => void) | null = null;
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";

  try {
    // ── Load pre-generated chain states ──
    const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
    if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
      throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, stateDir);
    const upgradeChainAddresses = selectUpgradeChains(chainAddresses, chains.config, scenario.targetRoles);
    if (upgradeChainAddresses.length === 0) {
      throw new Error(`No chains matched upgrade roles ${scenario.targetRoles.join(", ")} for ${scenario.label}`);
    }
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }
    const l1Provider = createProvider(l1Chain.rpcUrl);
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
    const oldVersion: ethers.BigNumber = await ctm.protocolVersion();
    console.log(`\nDeparting protocol version: ${oldVersion.toHexString()}`);

    // ── Transfer L1 contract ownership to governance ──
    console.log("\n── Preparing L1 ownership for upgrade ──");
    await transferL1Ownership(l1Provider, defaultSigner, l1Addresses, ctmAddresses);

    // ── Deploy ChainAdmin for each upgrade target ──
    console.log("\n── Deploying temporary ChainAdminOwnable contracts ──");
    await deployChainAdmins(l1Provider, defaultSigner, upgradeChainAddresses);

    // ── Optionally install the legacy cut-taking entrypoint (see module docs, step 3) ──
    if (scenario.installLegacyCutTakingFacet) {
      console.log("\n── Installing the legacy cut-taking entrypoint on target chains ──");
      const legacyFacet = await deployFromCreationBytecode(defaultSigner, "LegacyTestAdminFacet");
      await installLegacyFacet(
        l1Provider,
        ctmAddresses.chainTypeManager,
        legacyFacet,
        upgradeChainAddresses,
        sendAndCheck
      );
    }

    // ── Run ecosystem upgrade forge scripts via protocol-ops ──
    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
      l1Addresses,
      ctmAddresses,
      chainAddresses: upgradeChainAddresses,
    });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    console.log("\n── Preparing ecosystem upgrade bundles via protocol-ops ──");
    await runEcosystemUpgradeScripts({
      rpcUrl: l1Chain.rpcUrl,
      scenario,
      upgradeHarnessInputs,
      executeBundles: true,
    });

    // `upgrade-prepare-all` writes a single merged `ecosystem.toml` at the canonical tracked
    // path, carrying the one governance bundle of the core and CTM prepares.
    const mergedEcosystemToml = path.join(upgradeHarnessInputs.protocolOpsOutDir, "ecosystem.toml");
    if (!fs.existsSync(mergedEcosystemToml)) {
      throw new Error(`Merged ecosystem TOML not emitted by upgrade-prepare-all: ${mergedEcosystemToml}`);
    }
    const mergedBootstrap = parseToml(fs.readFileSync(mergedEcosystemToml, "utf8")) as MergedGovernanceOutput & {
      core?: { registry?: { core_transition_addr?: string } };
    };

    // The cut comes from the per-CTM prepare output (`chain_upgrade_diamond_cut`); the file name
    // is protocol-ops' convention (`upgrade_inner.rs`). The L2 leg is read from the migration
    // object the cut names, exactly as the engine reads it at execution.
    const ctmTomlPath = path.join(
      l1ContractsDir,
      "script-out",
      `upgrade-ctm-${upgradeHarnessInputs.ctmProxyAddress.toLowerCase()}.toml`
    );
    const { cut, migrationAddr, ctmExecutor } = readBootstrapPrepareOutput(ctmTomlPath);

    // The ChainAdmin's half of the one-time ServerNotifier handover rode the prepare (protocol-ops'
    // CTM admin calls); governance's accept is still to come, as the bundle's first call.
    const ctmProxyAdmin = await readProxyAdmin(l1Provider, ctmAddresses.chainTypeManager);
    await assertServerNotifierState(
      l1Provider,
      ctmAddresses.chainTypeManager,
      { admin: ctmProxyAdmin, pendingOwner: ctmExecutor },
      "under the CTM ProxyAdmin and nominating the CTM executor after the prepare"
    );

    // The merge's one extra here is the ValidatorTimelock accept: governance owns the CTM outright
    // (no pending accept) and the upgrade input does not redeploy the zk governance set.
    const bootstrapCoreTransition = mergedBootstrap.core?.registry?.core_transition_addr;
    if (!bootstrapCoreTransition || bootstrapCoreTransition === ethers.constants.AddressZero) {
      throw new Error("the core prepare did not report the bootstrap's core transition");
    }
    await assertBootstrapBundle(l1Provider, mergedBootstrap, migrationAddr, bootstrapCoreTransition);

    // ── Governance's review: the bundle is signed only once the package verifies ──
    // The bootstrap package carries the records of the executors it deploys, and every later hop
    // runs through those executors, so it is the record file the hops are verified with.
    const reviewedBuildHashes = path.join(upgradeHarnessInputs.protocolOpsOutDir, "reviewed-build-hashes.json");
    writeReviewedBuildHashes(reviewedBuildHashes);
    verifyPackageAsReviewed({
      command: "verify-bootstrap",
      rpcUrl: l1Chain.rpcUrl,
      ecosystemToml: mergedEcosystemToml,
      governance: l1Addresses.governance,
      reviewedBuildHashes,
      executorRecords: [],
    });

    // ── Execute the governance bundle via protocol-ops ──
    console.log("\n── Replaying the governance bundle ──");
    await runEcosystemGovernanceUpgrade({
      rpcUrl: l1Chain.rpcUrl,
      bridgehubAddress: upgradeHarnessInputs.bridgehubAddress,
      governanceTomlPaths: [mergedEcosystemToml],
      outDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "governance"),
      executeBundles: true,
    });

    const migration = new ethers.Contract(migrationAddr, getAbi("RegistryBootstrapMigration"), l1Provider);
    const notifierRow = (await migration.getManifest()).ctmProxyUpgrades[
      proxyUpgradeSlotIndex("CTMContract", "ServerNotifier")
    ];
    await assertServerNotifierState(
      l1Provider,
      ctmAddresses.chainTypeManager,
      {
        admin: ctmProxyAdmin,
        owner: ctmExecutor,
        pendingOwner: ethers.constants.AddressZero,
        implementation: notifierRow.implNew,
        chainTypeManager: ctmAddresses.chainTypeManager,
      },
      "held by the CTM executor and re-pointed by migrate() after the governance replay"
    );
    const validatorTimelock: string = await new ethers.Contract(
      ctmAddresses.chainTypeManager,
      getAbi("IChainTypeManager"),
      l1Provider
    ).validatorTimelockPostV29();
    const timelockOwner: string = await new ethers.Contract(
      validatorTimelock,
      getAbi("Ownable2Step"),
      l1Provider
    ).owner();
    if (timelockOwner.toLowerCase() !== l1Addresses.governance.toLowerCase()) {
      throw new Error(
        `ValidatorTimelock ${validatorTimelock} is owned by ${timelockOwner}, not governance, after the replay`
      );
    }
    console.log("  ✓ the ValidatorTimelock is governance-owned after the replay");
    await assertBootstrapCompleted(l1Provider, migrationAddr);

    // ── Prepare diamond state for chain upgrades ──
    if (scenario.clearGenesisUpgradeTxHash) {
      console.log("\n── Clearing legacy genesis upgrade tx hashes ──");
      await clearGenesisUpgradeTxHash(l1Provider, upgradeChainAddresses);
    }

    // ── Per-chain legacy crossing + L2 relay ──
    await runLegacyChainLegAndRelayL2({
      l1Provider,
      anvilManager,
      upgradeChainAddresses,
      oldVersion,
      cut,
      migrationAddr,
      ctmAddr: ctmAddresses.chainTypeManager,
      isZKsyncOS: scenario.isZKsyncOS,
      l2DelegateBytecodeName: scenario.l2DelegateBytecodeName,
    });

    console.log("\n── Chain upgrades complete, verifying final state ──");
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses, scenario.expectedProtocolVersion);
    await verifyCtmEndState(l1Provider, ctmAddresses.chainTypeManager, l1Addresses.governance, {
      oldVersion,
      expectedProtocolVersion: scenario.expectedProtocolVersion,
      migrationAddr,
    });
    await verifyInteropFeeManager(l1Provider, ctmAddresses.chainTypeManager, l1Addresses.bridgehub);
    console.log("✅ Pipeline upgrade scenario verified successfully!\n");

    // Each hop departs from the state the previous one left, and carries the EIP-7702 checker
    // forward the way a production env file does.
    let reportedEip7702Checker = readReportedEip7702Checker(mergedEcosystemToml);
    for (const hop of scenario.followUps ?? []) {
      reportedEip7702Checker = await runRecurringHop(scenario, hop, {
        l1Provider,
        rpcUrl: l1Chain.rpcUrl,
        l1Addresses,
        ctmAddresses,
        upgradeChainAddresses,
        eip7702Checker: reportedEip7702Checker,
        executorRecords: mergedEcosystemToml,
        reviewedBuildHashes,
      });
    }
  } finally {
    if (cleanupUpgradeHarnessInputs) {
      cleanupUpgradeHarnessInputs();
    }
    if (!keepChains) {
      await anvilManager.stopAll();
    }
  }
}

// ── Registry-driven follow-up hop ─────────────────────────────────────

/**
 * Which members two releases disagree on. Used to explain a failed reuse assertion: "the prepare
 * deployed a new release" is only actionable with the member that forced it.
 */
async function describeReleaseDifference(
  provider: ethers.providers.JsonRpcProvider,
  fromRelease: string,
  newRelease: string
): Promise<string> {
  const a = new ethers.Contract(fromRelease, getAbi("CTMRelease"), provider);
  const b = new ethers.Contract(newRelease, getAbi("CTMRelease"), provider);
  const differences: string[] = [];
  const compare = async (name: string, read: (c: ethers.Contract) => Promise<unknown>): Promise<void> => {
    const [left, right] = [await read(a), await read(b)];
    const encode = (v: unknown): string => JSON.stringify(v);
    if (encode(left) !== encode(right)) {
      differences.push(`${name}: ${encode(left)} -> ${encode(right)}`);
    }
  };
  await compare("diamondInit", (c) => c.diamondInit());
  await compare("verifier", (c) => c.verifier());
  await compare("genesisFacets", (c) => c.genesisFacets());
  await compare("genesisParams", (c) => c.genesisParams());
  await compare("fixedForceDeploymentsData", async (c) => ethers.utils.keccak256(await c.fixedForceDeploymentsData()));
  await compare("l2BytecodeInfos", async (c) =>
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["bytes[]"], [await c.l2BytecodeInfos()]))
  );
  await compare("l2SystemProxyBytecodeInfo", (c) => c.l2SystemProxyBytecodeInfo());
  return differences.length === 0 ? "no member differs (identical manifests)" : differences.join("; ");
}

/**
 * Throws unless every row the operation names — its CTM-domain rows and its core transition's
 * ecosystem rows — reads back at its `implNew`. Returns how many rows of each domain were checked.
 */
async function verifyOperationRowsApplied(
  provider: ethers.providers.JsonRpcProvider,
  operation: ethers.Contract
): Promise<{ ctmRows: number; ecosystemRows: number }> {
  const ctmRows: Array<{ proxy: string; implNew: string }> = [...(await operation.ctmInfrastructureRows())];
  const ecosystemRows: Array<{ proxy: string; implNew: string }> = [];
  const coreTransitionAddr: string = await operation.coreTransition();
  if (coreTransitionAddr !== ethers.constants.AddressZero) {
    const coreTransition = new ethers.Contract(coreTransitionAddr, getAbi("ICoreTransition"), provider);
    ecosystemRows.push(...(await coreTransition.ecosystemRows()));
  }
  for (const row of [...ctmRows, ...ecosystemRows]) {
    const live = await readProxyImplementation(provider, row.proxy);
    if (live.toLowerCase() !== row.implNew.toLowerCase()) {
      throw new Error(`proxy ${row.proxy} runs ${live}, but the operation's row installs ${row.implNew}`);
    }
  }
  return { ctmRows: ctmRows.length, ecosystemRows: ecosystemRows.length };
}

/**
 * The CTM domain's EIP-7702 checker as the previous prepare reported it. Production carries this
 * forward through the next upgrade's env input for a reason: the `MailboxFacet` pins it as an
 * immutable and nothing on-chain exposes it, so a prepare that is not told the live one deploys a
 * fresh checker — which moves the Mailbox and, with it, the whole release.
 */
function readReportedEip7702Checker(mergedEcosystemTomlPath: string): string | undefined {
  const merged = parseToml(fs.readFileSync(mergedEcosystemTomlPath, "utf8")) as {
    ctms?: { zksync_os?: { state_transition?: { eip7702_checker_addr?: string } } };
  };
  const reported = merged.ctms?.zksync_os?.state_transition?.eip7702_checker_addr;
  return reported && reported !== ethers.constants.AddressZero ? reported : undefined;
}

/**
 * The registry-driven hop that follows the bootstrap on the same chains — the production shape
 * of every upgrade after v35, driven by the real toolchain end to end:
 *
 *   1. protocol-ops `upgrade-prepare-all` runs the (trimmed) v36 prepares: the core prepare
 *      deploys one ecosystem implementation and pins it in a `CoreTransition`; the CTM prepare
 *      deploys the release, the `CTMTransition` and the `EcosystemUpgradeOperation` naming both.
 *   2. The merged `ecosystem.toml` is asserted to carry exactly one call, the derived
 *      `execute(operation)` on the coordinator, and no `external_actions` at all — the tooling
 *      claim, checked on the artifact — and `protocol-ops ecosystem verify-package` must pass on it.
 *   3. The governance replay executes it; each chain then crosses through the cut-READING
 *      `upgradeChainFromVersion` as its own admin (no cut is handed over).
 *   4. End state: `OperationExecuted(operation)` emitted once, chains and CTM at the new version,
 *      the transition committed for the departing version, the CTM on the transition's release,
 *      and every row the operation names (core and CTM-domain) at its `implNew`.
 */
async function runRecurringHop(
  scenario: PipelineUpgradeScenario,
  hop: RecurringUpgradeHop,
  ctx: {
    l1Provider: ethers.providers.JsonRpcProvider;
    rpcUrl: string;
    l1Addresses: { bridgehub: string; governance: string; messageRoot: string };
    ctmAddresses: { chainTypeManager: string };
    upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
    /** The live EIP-7702 checker as the previous hop's prepare reported it. */
    eip7702Checker?: string;
    /** The bootstrap package: the records of the executors every hop runs through. */
    executorRecords: string;
    /** The hashes of the build the scenario deploys from (see `writeReviewedBuildHashes`). */
    reviewedBuildHashes: string;
  }
): Promise<string | undefined> {
  console.log(`\n══ Registry-driven follow-up hop: ${hop.label} ══`);
  const { l1Provider, upgradeChainAddresses } = ctx;
  const ctm = new ethers.Contract(ctx.ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
  const oldVersion: ethers.BigNumber = await ctm.protocolVersion();
  console.log(`  departing protocol version: ${oldVersion.toHexString()}`);

  // The previous hop's L2 leg is still "pending" on these sequencer-less chains (see module docs),
  // which blocks a MINOR upgrade. A patch hop deliberately keeps it, to prove it survives.
  const pendingL2TxHashes = new Map<number, string>();
  if (hop.keepsPendingL2Upgrade) {
    for (const chain of upgradeChainAddresses) {
      const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
      pendingL2TxHashes.set(chain.chainId, await getters.getL2SystemContractsUpgradeTxHash());
    }
    const anyPending = [...pendingL2TxHashes.values()].some((h) => h !== ethers.constants.HashZero);
    if (!anyPending) {
      throw new Error(`hop ${hop.label} is meant to run with a pending L2 upgrade, but none is recorded`);
    }
    console.log("  keeping the pending L2 upgrade transaction: a patch must not disturb it");
  } else {
    await clearGenesisUpgradeTxHash(l1Provider, upgradeChainAddresses);
  }

  const hopScenario: PipelineUpgradeScenario = {
    ...scenario,
    label: hop.label,
    upgradeInputTemplatePath: hop.upgradeInputTemplatePath,
    expectedProtocolVersion: hop.expectedProtocolVersion,
    coreScriptPath: hop.coreScriptPath,
    ctmScriptPath: hop.ctmScriptPath,
    followUps: undefined,
  };
  const inputs = prepareUpgradeHarnessInputs(hopScenario, {
    l1Addresses: ctx.l1Addresses,
    ctmAddresses: ctx.ctmAddresses,
    chainAddresses: upgradeChainAddresses,
    eip7702Checker: ctx.eip7702Checker,
  });
  try {
    console.log("\n── Preparing the registry-driven upgrade via protocol-ops ──");
    await runEcosystemUpgradeScripts({
      rpcUrl: ctx.rpcUrl,
      scenario: hopScenario,
      upgradeHarnessInputs: inputs,
      executeBundles: true,
    });
    const mergedEcosystemToml = path.join(inputs.protocolOpsOutDir, "ecosystem.toml");
    if (!fs.existsSync(mergedEcosystemToml)) {
      throw new Error(`Merged ecosystem TOML not emitted by upgrade-prepare-all: ${mergedEcosystemToml}`);
    }
    const merged = parseToml(fs.readFileSync(mergedEcosystemToml, "utf8")) as MergedGovernanceOutput & {
      core: {
        registry?: { core_transition_addr?: string };
        upgrade_addresses?: { bridgehub?: { message_root_implementation_addr?: string } };
      };
      ctms: {
        zksync_os: {
          registry?: {
            ctm_transition_addr?: string;
            ctm_upgrade_executor_addr?: string;
            ctm_release_addr?: string;
            operation_addr?: string;
            coordinator_addr?: string;
          };
        };
      };
      operation?: { operation_addr?: string; coordinator_addr?: string };
    };
    const registry = merged.ctms.zksync_os.registry ?? {};
    const transitionAddr = registry.ctm_transition_addr;
    const executorAddr = registry.ctm_upgrade_executor_addr;
    if (!transitionAddr || !executorAddr || transitionAddr === ethers.constants.AddressZero) {
      throw new Error("the CTM prepare did not report its transition and bound executor");
    }
    const operationAddr = registry.operation_addr;
    const coordinatorAddr = registry.coordinator_addr;
    if (!operationAddr || !coordinatorAddr || operationAddr === ethers.constants.AddressZero) {
      throw new Error("the CTM prepare did not report the operation and its coordinator");
    }
    // The merge may restate them in its own `[operation]` table; it must name the same pair.
    if (
      merged.operation &&
      (merged.operation.operation_addr?.toLowerCase() !== operationAddr.toLowerCase() ||
        merged.operation.coordinator_addr?.toLowerCase() !== coordinatorAddr.toLowerCase())
    ) {
      throw new Error("the merged [operation] table names a different operation or coordinator than the CTM prepare");
    }
    console.log(
      `  transition:  ${transitionAddr}\n  executor:    ${executorAddr}\n  operation:   ${operationAddr}\n  coordinator: ${coordinatorAddr}`
    );

    // ── The tooling claim, checked on the artifact ──
    const coordinatorIface = new ethers.utils.Interface(getAbi("EcosystemUpgradeExecutor"));
    assertRegistryHopBundle(merged, {
      label: "coordinator.execute(operation)",
      target: coordinatorAddr,
      data: coordinatorIface.encodeFunctionData("execute", [operationAddr]),
    });
    // The operation names the transition; the coordinator binds the CTM executor.
    const operation = new ethers.Contract(operationAddr, getAbi("EcosystemUpgradeOperation"), l1Provider);
    const coordinator = new ethers.Contract(coordinatorAddr, getAbi("EcosystemUpgradeExecutor"), l1Provider);
    const namedTransition: string = await operation.ctmTransition();
    const boundExecutor: string = await coordinator.ctmExecutor();
    if (
      namedTransition.toLowerCase() !== transitionAddr.toLowerCase() ||
      boundExecutor.toLowerCase() !== executorAddr.toLowerCase()
    ) {
      throw new Error("the operation transition or coordinator CTM binding differs from the prepared upgrade");
    }
    const namedCoreTransition: string = await operation.coreTransition();
    const preparedCoreTransition = merged.core.registry?.core_transition_addr ?? ethers.constants.AddressZero;
    if (namedCoreTransition.toLowerCase() !== preparedCoreTransition.toLowerCase()) {
      throw new Error(
        `the operation names core transition ${namedCoreTransition}, the core prepare pinned ${preparedCoreTransition}`
      );
    }
    console.log("  ✓ the merged bundle is exactly execute(operation), with no external actions");

    verifyPackageAsReviewed({
      command: "verify-package",
      rpcUrl: ctx.rpcUrl,
      ecosystemToml: mergedEcosystemToml,
      governance: ctx.l1Addresses.governance,
      reviewedBuildHashes: ctx.reviewedBuildHashes,
      executorRecords: [ctx.executorRecords],
    });

    const messageRootImplBefore = await readProxyImplementation(l1Provider, ctx.l1Addresses.messageRoot);

    // ── Governance executes the operation ──
    console.log("\n── Replaying the coordinator call via protocol-ops ──");
    const replayFromBlock = await l1Provider.getBlockNumber();
    await runEcosystemGovernanceUpgrade({
      rpcUrl: ctx.rpcUrl,
      bridgehubAddress: inputs.bridgehubAddress,
      governanceTomlPaths: [mergedEcosystemToml],
      outDir: path.join(inputs.protocolOpsOutDir, "governance"),
      executeBundles: true,
    });

    // ── Each chain crosses through the cut-READING entrypoint, as its own admin ──
    console.log("\n── Chains cross the registry-driven edge ──");
    const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
    for (const chain of upgradeChainAddresses) {
      const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
      const admin: string = await getters.getAdmin();
      const data = adminIface.encodeFunctionData("upgradeChainFromVersion", [chain.diamondProxy, oldVersion]);
      await impersonateAndRun(l1Provider, admin, async (signer) => {
        await sendAndCheck(
          l1Provider,
          signer.sendTransaction({ to: chain.diamondProxy, data, gasLimit: 10_000_000 }),
          `chain ${chain.chainId}: upgradeChainFromVersion(${oldVersion.toHexString()})`
        );
      });
      console.log(`  ✓ chain ${chain.chainId} crossed the registry-driven edge (cut read from the CTM)`);
    }

    // ── End state ──
    console.log("\n── Verifying the registry-driven end state ──");
    const executed = await coordinator.queryFilter(
      coordinator.filters.OperationExecuted(operationAddr),
      replayFromBlock
    );
    if (executed.length !== 1) {
      throw new Error(
        `the replay emitted OperationExecuted(${operationAddr}) ${executed.length} time(s), expected once`
      );
    }
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses, hop.expectedProtocolVersion);
    const version: ethers.BigNumber = await ctm.protocolVersion();
    if (!version.eq(ethers.BigNumber.from(hop.expectedProtocolVersion))) {
      throw new Error(`CTM protocol version ${version.toHexString()}, expected ${hop.expectedProtocolVersion}`);
    }
    const committed: string = await ctm.upgradeTransition(oldVersion);
    if (committed.toLowerCase() !== transitionAddr.toLowerCase()) {
      throw new Error(`CTM committed transition ${committed} for the departing version, expected ${transitionAddr}`);
    }
    const executor = new ethers.Contract(executorAddr, getAbi("CTMUpgradeExecutor"), l1Provider);
    await executor.validateTransitionApplied(transitionAddr);
    const transition = new ethers.Contract(transitionAddr, getAbi("ICTMTransition"), l1Provider);
    const newRelease: string = await transition.newRelease();
    const currentRelease: string = await ctm.currentRelease();
    if (currentRelease.toLowerCase() !== newRelease.toLowerCase()) {
      throw new Error(`CTM currentRelease ${currentRelease} is not the transition's target release ${newRelease}`);
    }
    // Read off the OBJECT rather than the prepare's logs: this is what governance and the chains
    // read, and it is the only evidence that unchanged contracts were not silently redeployed.
    if (hop.expectsReusedReleaseMembers) {
      const fromRelease: string = await transition.fromRelease();
      const diff: Record<string, unknown> = await transition.releaseDiff();
      const changed = Object.keys(diff).filter((key) => Number.isNaN(Number(key)) && diff[key] === true);
      if (changed.length !== 0) {
        const difference = await describeReleaseDifference(l1Provider, fromRelease, newRelease);
        throw new Error(
          `hop ${hop.label} changes no release member, so the prepare must reuse every live one; ` +
            `releaseDiff names ${changed.join(", ")}. Differing members: ${difference}`
        );
      }
      console.log("  ✓ the prepare reused every release member: the new release differs in its version alone");
    }
    if (hop.expectsReusedReleaseMembers || hop.expectsEmptyFacetDelta) {
      const facetCuts: unknown[] = await transition.facetCuts();
      if (facetCuts.length !== 0) {
        throw new Error(
          `hop ${hop.label} changes no facet, so its derived facet delta must be empty (got ${facetCuts.length} cut(s))`
        );
      }
      console.log("  ✓ identical routing on both edges derived an empty facet delta");
    }
    const appliedRows = await verifyOperationRowsApplied(l1Provider, operation);
    console.log(
      "  ✓ OperationExecuted emitted once; transition committed; " +
        `${appliedRows.ctmRows} CTM-domain and ${appliedRows.ecosystemRows} ecosystem row(s) at implNew`
    );
    if (hop.expectsFreshMessageRoot) {
      // The ecosystem leg must really apply: a row whose implementation the proxy already ran
      // would pass every check above while changing nothing.
      if (appliedRows.ecosystemRows < 1) {
        throw new Error(`hop ${hop.label} redeploys L1MessageRoot, but its operation applied no ecosystem row`);
      }
      const expectedMessageRootImpl = merged.core.upgrade_addresses?.bridgehub?.message_root_implementation_addr;
      if (!expectedMessageRootImpl) {
        throw new Error("the core prepare did not report the fresh L1MessageRoot implementation");
      }
      const liveMessageRootImpl = await readProxyImplementation(l1Provider, ctx.l1Addresses.messageRoot);
      if (liveMessageRootImpl.toLowerCase() === messageRootImplBefore.toLowerCase()) {
        throw new Error(`MessageRoot proxy still points at ${liveMessageRootImpl}: the hop did not move it`);
      }
      if (liveMessageRootImpl.toLowerCase() !== expectedMessageRootImpl.toLowerCase()) {
        throw new Error(
          `MessageRoot proxy points at ${liveMessageRootImpl}, expected the fresh ${expectedMessageRootImpl}`
        );
      }
      console.log(`  ✓ L1MessageRoot moved ${messageRootImplBefore} -> ${liveMessageRootImpl}`);
    }
    for (const chain of upgradeChainAddresses) {
      const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
      const recorded: string = await getters.getL2SystemContractsUpgradeTxHash();
      if (hop.keepsPendingL2Upgrade) {
        // The whole point of a patch edge: it may not carry an L2 upgrade, and it may not disturb
        // one that is already committed and unfinalized.
        const before = pendingL2TxHashes.get(chain.chainId);
        if (recorded !== before) {
          throw new Error(
            `chain ${chain.chainId}: the patch changed the pending L2 upgrade transaction (${before} -> ${recorded})`
          );
        }
      } else if (recorded !== ethers.constants.HashZero) {
        throw new Error(
          `chain ${chain.chainId}: an L1-only edge must not record an L2 upgrade transaction (${recorded})`
        );
      }
    }
    if (hop.keepsPendingL2Upgrade) {
      console.log("  ✓ the pending L2 upgrade transaction survived the patch untouched");
    }
    console.log(
      `✅ Registry-driven hop ${hop.label} verified: one call, one transition, chains at ${hop.expectedProtocolVersion}\n`
    );
    return readReportedEip7702Checker(mergedEcosystemToml) ?? ctx.eip7702Checker;
  } finally {
    inputs.cleanup();
  }
}

// ── Shared tx helper ─────────────────────────────────────────────────

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
  recordL1TransactionGas(receipt, tx.gasLimit, {
    phase: "chain-upgrade",
    bundle: label,
    index: 1,
    target: tx.to!,
  });
  return receipt;
}

async function deployFromCreationBytecode(signer: ethers.Wallet, name: ContractName): Promise<string> {
  const factory = new ethers.ContractFactory(getAbi(name), getCreationBytecode(name), signer);
  const contract = await factory.deploy();
  await contract.deployed();
  return contract.address;
}

// ── L1 ownership & admin setup ───────────────────────────────────────

async function transferL1Ownership(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  l1Addresses: {
    governance: string;
    bridgehub: string;
    l1SharedBridge: string;
    l1NativeTokenVault: string;
    l1NullifierProxy?: string;
  },
  ctmAddresses: { chainTypeManager: string }
): Promise<void> {
  const gov = l1Addresses.governance;
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.bridgehub);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1SharedBridge);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NativeTokenVault);
  await transferOwnership2Step(provider, defaultSigner, gov, ctmAddresses.chainTypeManager);
  // A production ecosystem hands the nullifier to governance at deploy time; the fixtures leave
  // it with the deployer.
  if (l1Addresses.l1NullifierProxy) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NullifierProxy);
  }
  await normalizeProxyAdminOwnerToEoa(provider, defaultSigner, ctmAddresses.chainTypeManager);
}

/**
 * Hand the CTM's ProxyAdmin to governance when a contract owns it.
 *
 * The fixture's CTM deployment leaves its ProxyAdmin owned by its own `Governance.sol`
 * instance; the bootstrap bundle's handover (`ProxyAdmin.transferOwnership(migration)`) is a
 * plain governance call, so governance itself has to be the owner.
 */
async function normalizeProxyAdminOwnerToEoa(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  proxyAddress: string
): Promise<void> {
  const proxyAdmin = await readProxyAdmin(provider, proxyAddress);

  const proxyAdminContract = new ethers.Contract(proxyAdmin, getAbi("ProxyAdmin"), provider);
  const owner: string = await proxyAdminContract.owner();
  if ((await provider.getCode(owner)) === "0x") {
    return;
  }

  console.log(`   Normalizing ProxyAdmin ${proxyAdmin} owner ${owner} -> ${defaultSigner.address}`);
  await provider.send("anvil_impersonateAccount", [owner]);
  await provider.send("anvil_setBalance", [owner, "0x56BC75E2D63100000"]);
  const ownerSigner = provider.getSigner(owner);
  const tx = await ownerSigner.sendTransaction({
    to: proxyAdmin,
    data: proxyAdminContract.interface.encodeFunctionData("transferOwnership", [defaultSigner.address]),
    gasLimit: 5_000_000,
  });
  await tx.wait();
  await provider.send("anvil_stopImpersonatingAccount", [owner]);
}

async function deployChainAdmins(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  const chainAdminFactory = new ethers.ContractFactory(
    getAbi("ChainAdminOwnable"),
    getCreationBytecode("ChainAdminOwnable"),
    defaultSigner
  );
  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));

  for (const chain of chains) {
    const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
    const currentAdmin = await diamondProxy.getAdmin();

    const chainAdmin = await chainAdminFactory.deploy(ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_ACCOUNT_ADDR);
    await chainAdmin.deployed();

    // Transfer admin: old admin → setPendingAdmin → new admin accepts
    await impersonateAndRun(provider, currentAdmin, async (signer) => {
      const tx = await signer.sendTransaction({
        to: chain.diamondProxy,
        data: adminIface.encodeFunctionData("setPendingAdmin", [chainAdmin.address]),
        gasLimit: 1_000_000,
      });
      return tx.wait();
    });

    const chainAdminContract = new ethers.Contract(chainAdmin.address, getAbi("ChainAdminOwnable"), defaultSigner);
    const acceptTx = await chainAdminContract.multicall(
      [{ target: chain.diamondProxy, value: 0, data: adminIface.encodeFunctionData("acceptAdmin", []) }],
      true
    );
    await acceptTx.wait();
  }
}

// ── Protocol-ops bundle generation/replay ───────────────────────────

type UpgradeHarnessInputs = ReturnType<typeof prepareUpgradeHarnessInputs>;

function runProtocolOps(args: string[], extraEnv?: Record<string, string>): void {
  const result = spawnSync("./protocol-ops.sh", args, {
    cwd: contractsRootDir,
    stdio: "inherit",
    env: {
      ...process.env,
      ...extraEnv,
      PROTOCOL_CONTRACTS_ROOT: contractsRootDir,
    },
  });
  if (result.status !== 0) {
    throw new Error(`protocol-ops failed: ${args.join(" ")}`);
  }
}

/**
 * Writes the hashes of the build that deploys this scenario's objects (`scripts/calculate-hashes.ts
 * --output`), for `verify-package --contract-hashes`. The committed `AllContractsHashes.json` is
 * regenerated last, after the sources are final, so it does not describe the working tree a run
 * deploys from; the verifier still holds every local artifact it reads against this file.
 */
function writeReviewedBuildHashes(outputPath: string): void {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const result = spawnSync(
    path.join(contractsRootDir, "node_modules", ".bin", "ts-node"),
    ["scripts/calculate-hashes.ts", "--output", outputPath],
    { cwd: contractsRootDir, stdio: "inherit" }
  );
  if (result.status !== 0) {
    throw new Error("scripts/calculate-hashes.ts --output failed: build l1-contracts first");
  }
}

/**
 * `protocol-ops ecosystem verify-bootstrap` / `verify-package` (one command, two names) on a merged
 * prepare output, run the way a reviewer runs it before governance signs: against the live L1, the
 * reviewed governance owner and the `local` env's permanent values. Throws when the verifier reports
 * any error.
 */
function verifyPackageAsReviewed(params: {
  command: "verify-bootstrap" | "verify-package";
  rpcUrl: string;
  ecosystemToml: string;
  governance: string;
  reviewedBuildHashes: string;
  /** Files carrying `[upgrade_executors]` records the package itself does not carry. */
  executorRecords: string[];
}): void {
  console.log(`\n── ${params.command}: reviewing the package before governance replays it ──`);
  runProtocolOps([
    "ecosystem",
    params.command,
    "--ecosystem-toml",
    params.ecosystemToml,
    "--l1-rpc-url",
    params.rpcUrl,
    "--expected-governance-owner",
    params.governance,
    "--env",
    "local",
    "--contract-hashes",
    params.reviewedBuildHashes,
    ...params.executorRecords.flatMap((record) => ["--executor-record", record]),
  ]);
}

function safeBundlesInDir(dir: string): Array<{ file: string; target: string }> {
  const manifestPath = path.join(dir, "manifest.json");
  if (fs.existsSync(manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as {
      bundles?: Array<{ index?: number; file?: string; target?: string }>;
    };
    return (manifest.bundles ?? [])
      .filter((bundle): bundle is { index: number; file: string; target: string } => {
        return typeof bundle.index === "number" && typeof bundle.file === "string" && typeof bundle.target === "string";
      })
      .sort((a, b) => a.index - b.index)
      .map((bundle) => ({ file: path.join(dir, bundle.file), target: bundle.target }));
  }

  return fs
    .readdirSync(dir)
    .filter((file) => file.endsWith(".safe.json"))
    .sort()
    .map((file) => ({ file: path.join(dir, file), target: ANVIL_DEFAULT_ACCOUNT_ADDR }));
}

async function executeSafeBundles(outDir: string, rpcUrl: string, phase: "prepare" | "governance"): Promise<void> {
  if (!fs.existsSync(outDir)) {
    throw new Error(`Protocol-ops output directory does not exist: ${outDir}`);
  }
  const safeBundles = safeBundlesInDir(outDir);
  if (safeBundles.length === 0) {
    throw new Error(`No protocol-ops Safe bundles found in ${outDir}`);
  }
  const provider = createProvider(rpcUrl);

  for (const bundle of safeBundles) {
    const safeFile = JSON.parse(fs.readFileSync(bundle.file, "utf8")) as {
      transactions?: Array<{ to: string; value: string; data: string }>;
    };
    const transactions = safeFile.transactions ?? [];
    if (transactions.length === 0) {
      throw new Error(`Safe bundle has no transactions: ${bundle.file}`);
    }

    await provider.send("anvil_impersonateAccount", [bundle.target]);
    await provider.send("anvil_setBalance", [bundle.target, "0x56BC75E2D63100000"]);
    const signer = provider.getSigner(bundle.target);
    try {
      for (let i = 0; i < transactions.length; i++) {
        const tx = await signer.sendTransaction({
          to: transactions[i].to,
          value: ethers.BigNumber.from(transactions[i].value),
          data: transactions[i].data,
          gasLimit: ETHEREUM_L1_TX_GAS_LIMIT,
        });
        const receipt = await tx.wait();
        if (receipt.status !== 1) {
          const trace = await traceFailedTx(provider, receipt.transactionHash);
          throw new Error(
            `Safe bundle ${path.basename(bundle.file)} tx ${i + 1}/${transactions.length} reverted:\n${trace}`
          );
        }
        recordL1TransactionGas(receipt, tx.gasLimit, {
          phase,
          bundle: path.basename(bundle.file),
          index: i + 1,
          target: transactions[i].to,
        });
      }
    } finally {
      await provider.send("anvil_stopImpersonatingAccount", [bundle.target]);
    }
  }
}

export async function runEcosystemUpgradeScripts(params: {
  rpcUrl: string;
  scenario: PipelineUpgradeScenario;
  upgradeHarnessInputs: UpgradeHarnessInputs;
  executeBundles?: boolean;
}): Promise<void> {
  const prepareOutDir = path.join(params.upgradeHarnessInputs.protocolOpsOutDir, "prepare");
  fs.rmSync(prepareOutDir, { recursive: true, force: true });

  // Addresses are passed explicitly rather than auto-resolved: the snapshot config is
  // authoritative for the loaded fixture.
  runProtocolOps(
    [
      "ecosystem",
      "upgrade-prepare-all",
      "--bridgehub",
      params.upgradeHarnessInputs.bridgehubAddress,
      "--l1-rpc-url",
      params.rpcUrl,
      "--out",
      prepareOutDir,
      "--deployer-address",
      ANVIL_DEFAULT_ACCOUNT_ADDR,
      "--ctm-proxy",
      params.upgradeHarnessInputs.ctmProxyAddress,
      "--rollup-da-manager-address",
      params.upgradeHarnessInputs.rollupDaManagerAddress,
      "--create2-factory-salt",
      params.upgradeHarnessInputs.create2FactorySalt,
      "--upgrade-input-path",
      params.upgradeHarnessInputs.upgradeInputArg,
      ...(params.scenario.coreScriptPath ? ["--core-script-path", params.scenario.coreScriptPath] : []),
      ...(params.scenario.ctmScriptPath ? ["--ctm-script-path", params.scenario.ctmScriptPath] : []),
      "--additional-args=--memory-limit=536870912",
    ],
    params.upgradeHarnessInputs.envVars
  );

  if (params.executeBundles) {
    await executeSafeBundles(prepareOutDir, params.rpcUrl, "prepare");
  }
}

export async function runEcosystemGovernanceUpgrade(params: {
  rpcUrl: string;
  bridgehubAddress: string;
  governanceTomlPaths: string[];
  outDir: string;
  executeBundles?: boolean;
}): Promise<void> {
  if (params.governanceTomlPaths.length === 0) {
    throw new Error("runEcosystemGovernanceUpgrade requires at least one governance TOML");
  }
  fs.rmSync(params.outDir, { recursive: true, force: true });

  const args: string[] = [
    "ecosystem",
    "upgrade-governance",
    "--bridgehub",
    params.bridgehubAddress,
    "--l1-rpc-url",
    params.rpcUrl,
    "--out",
    params.outDir,
  ];
  for (const toml of params.governanceTomlPaths) {
    args.push("--governance-toml", toml);
  }
  runProtocolOps(args);

  if (params.executeBundles) {
    await executeSafeBundles(params.outDir, params.rpcUrl, "governance");
  }
}

// ── Committed cut + the migration it names ───────────────────────────

const DIAMOND_CUT_TYPE =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";

/**
 * Read the committed upgrade cut from the per-CTM light output and resolve the pinned
 * `RegistryBootstrapMigration` its init calldata names (the engine's `upgradeFromBootstrap(address)`
 * delegatecall payload), plus the bound CTM executor the prepare deployed. The engine reads the
 * edge's L2 leg from that object at execution; so does this harness.
 */
function readBootstrapPrepareOutput(ctmTomlPath: string): {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  cut: any;
  migrationAddr: string;
  ctmExecutor: string;
} {
  if (!fs.existsSync(ctmTomlPath)) {
    throw new Error(`Missing per-CTM prepare output ${ctmTomlPath}. Did upgrade-prepare-all run?`);
  }
  const ctmOutput = parseToml(fs.readFileSync(ctmTomlPath, "utf8")) as {
    chain_upgrade_diamond_cut?: string;
    registry?: { ctm_upgrade_executor_addr?: string };
  };
  const cutBytes = ctmOutput.chain_upgrade_diamond_cut;
  if (typeof cutBytes !== "string" || cutBytes.length < 4) {
    throw new Error(`No chain_upgrade_diamond_cut in ${ctmTomlPath}`);
  }
  const [cut] = ethers.utils.defaultAbiCoder.decode([DIAMOND_CUT_TYPE], cutBytes);

  const engineIface = new ethers.utils.Interface(getAbi("BootstrapUpgrade"));
  const [migrationAddr] = engineIface.decodeFunctionData("upgradeFromBootstrap", cut.initCalldata);

  const ctmExecutor = ctmOutput.registry?.ctm_upgrade_executor_addr;
  if (!ctmExecutor || ctmExecutor === ethers.constants.AddressZero) {
    throw new Error(`No registry.ctm_upgrade_executor_addr in ${ctmTomlPath}`);
  }
  return { cut, migrationAddr, ctmExecutor };
}

// ── Per-chain legacy crossing + L2 relay ─────────────────────────────

async function runLegacyChainLegAndRelayL2(params: {
  l1Provider: ethers.providers.JsonRpcProvider;
  anvilManager: AnvilManager;
  upgradeChainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  oldVersion: ethers.BigNumber;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  cut: any;
  migrationAddr: string;
  ctmAddr: string;
  isZKsyncOS: boolean;
  l2DelegateBytecodeName: ContractName;
}): Promise<void> {
  // The L2 leg is composed PER CHAIN by the migration object — the FINAL transaction, exactly as
  // the engine commits it at the crossing (there is no later rewrite).
  const migration = new ethers.Contract(params.migrationAddr, getAbi("RegistryBootstrapMigration"), params.l1Provider);
  const l2TxParamType = migration.interface.getFunction("l2UpgradeTx").outputs?.[0];
  if (!l2TxParamType) {
    throw new Error("RegistryBootstrapMigration ABI has no l2UpgradeTx output");
  }

  for (const chain of params.upgradeChainAddresses) {
    console.log(`\n── Chain ${chain.chainId}: legacy handed-cut crossing ──`);

    // The per-chain upgrade requires `totalBatchesCommitted == totalBatchesExecuted`. On a
    // forked chain with uncommitted-but-pending batches at fork time, model the "all batches
    // executed" prerequisite without running the executor.
    await forceBatchExecutedEqualsCommitted(params.l1Provider, chain.diamondProxy);

    await crossBootstrapEdgeOnChains(params.l1Provider, [chain], params.oldVersion, params.cut, sendAndCheck);

    const l2Tx = await migration.l2UpgradeTx(chain.chainId);
    if (ethers.BigNumber.from(l2Tx.txType).isZero()) {
      console.log(`  chain ${chain.chainId}: no L2 leg in the proposed upgrade (txType 0)`);
      continue;
    }

    // The chain must have recorded exactly the transaction being relayed — `BaseZkSyncUpgrade`
    // stores keccak256(abi.encode(l2ProtocolUpgradeTx)) of the chain's own composition, and the
    // diamond only stores the hash, so the object's per-chain view is what is relayed.
    const expectedHash = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([l2TxParamType], [l2Tx]));
    const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), params.l1Provider);
    const recordedHash: string = await getters.getL2SystemContractsUpgradeTxHash();
    if (recordedHash.toLowerCase() !== expectedHash.toLowerCase()) {
      throw new Error(
        `Chain ${chain.chainId}: the diamond recorded L2 upgrade tx ${recordedHash}, but the transaction ` +
          `being relayed hashes to ${expectedHash}.`
      );
    }
    console.log(`   Recorded L2 upgrade tx hash matches the relayed transaction (${expectedHash})`);

    const l2Chain = params.anvilManager.getL2Chains().find((c) => c.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }
    const l2Provider = createProvider(l2Chain.rpcUrl);

    const l2TxHash = await prepareAndRelayL2Upgrade(
      l2Provider,
      l2Tx.data,
      params.isZKsyncOS,
      params.l2DelegateBytecodeName
    );
    console.log(`  ✅ L2 upgrade relay tx: ${l2TxHash}`);

    await verifyL2UpgradeResult(l2Provider, chain.chainId);
  }
}

/**
 * Deploy all L2 system contracts, then relay the upgrade tx.
 *
 * On Anvil EVM, neither the Era ContractDeployer nor ZKsyncOS bytecode deployer infrastructure
 * works. Instead we pre-deploy all known contracts via anvil_setCode and place a
 * MockContractDeployer at 0x8006.
 */
async function prepareAndRelayL2Upgrade(
  l2Provider: ethers.providers.JsonRpcProvider,
  upgradeTxData: string,
  isZKsyncOS: boolean,
  l2DelegateBytecodeName: ContractName
): Promise<string> {
  const { forceDeployEntries, delegateTo } = decodeUpgradeTxData(upgradeTxData);

  await deployL2Contracts(l2Provider, forceDeployEntries, delegateTo, isZKsyncOS, l2DelegateBytecodeName);

  const txHash = await impersonateAndRun(l2Provider, L2_FORCE_DEPLOYER_ADDR, async (signer) => {
    const tx = await signer.sendTransaction({
      to: L2_COMPLEX_UPGRADER_ADDR,
      data: upgradeTxData,
      gasLimit: 100_000_000,
    });
    return tx.hash;
  });
  const receipt = await l2Provider.waitForTransaction(txHash);

  if (receipt.status !== 1) {
    const trace = await traceFailedTx(l2Provider, receipt.transactionHash);
    throw new Error(`L2 upgrade relay reverted:\n${trace}`);
  }
  return receipt.transactionHash;
}

// ── L2 contract deployment ───────────────────────────────────────────

export async function deployL2Contracts(
  l2Provider: ethers.providers.JsonRpcProvider,
  forceDeployEntries: ForceDeployEntry[],
  delegateTo: string,
  isZKsyncOS: boolean,
  l2DelegateBytecodeName: ContractName
): Promise<void> {
  // MockContractDeployer: no-op fallback at ContractDeployer address so that forceDeployEra()
  // and conductContractUpgrade() calls succeed silently.
  await l2Provider.send("anvil_setCode", [L2_CONTRACT_DEPLOYER_ADDR, getBytecode("MockContractDeployer")]);

  await l2Provider.send("anvil_setCode", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    getBytecode("SystemContractProxyAdmin"),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    ethers.utils.hexZeroPad("0x0", 32), // slot 0: Ownable._owner
    ethers.utils.hexZeroPad(L2_COMPLEX_UPGRADER_ADDR, 32),
  ]);

  const contractMap = buildAddressToContract(isZKsyncOS);
  for (const entry of forceDeployEntries) {
    if (entry.upgradeType === UPGRADE_TYPE_ZKOS_UNSAFE_FORCE_DEPLOY) {
      continue;
    }

    const contractName = contractMap.get(entry.address.toLowerCase());
    if (!contractName) {
      if (entry.upgradeType === UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT) {
        continue;
      }
      throw new Error(`No contract mapping for ZKsyncOS force deploy address ${entry.address}`);
    }

    if (isZKsyncOS && entry.upgradeType === UPGRADE_TYPE_ZKOS_SYSTEM_PROXY) {
      if (!entry.deployedBytecodeInfo) {
        throw new Error(`ZKsyncOSSystemProxyUpgrade entry ${entry.address} missing deployedBytecodeInfo`);
      }
      await deployBehindSystemProxy(l2Provider, entry.address, getBytecode(contractName), entry.deployedBytecodeInfo);
    } else {
      await l2Provider.send("anvil_setCode", [entry.address, getBytecode(contractName)]);
    }
  }

  // Deploy the delegate target of the ComplexUpgrader call.
  await l2Provider.send("anvil_setCode", [delegateTo, getBytecode(l2DelegateBytecodeName)]);

  // L2BaseToken.initL2 mints an initial balance into the BaseTokenHolder and then transfers
  // ETH to it, so the token needs a non-zero balance on the anvil chain.
  await l2Provider.send("anvil_setBalance", [L2_BASE_TOKEN_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE]);

  // Seed critical storage values on L2 contracts deployed via anvil_setCode but never
  // initialized (performForceDeployedContractsInit reads these before calling updateL2).
  const toSlot = (n: number) => ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 32);
  const toAddr = (a: string) => ethers.utils.hexZeroPad(a, 32);

  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_WETH_TOKEN_SLOT),
    toAddr(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR),
  ]);
  await l2Provider.send("anvil_setStorageAt", [
    L2_NATIVE_TOKEN_VAULT_ADDR,
    toSlot(NTV_L1_CHAIN_ID_SLOT),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(runtimeConfig.l1ChainId), 32),
  ]);
}

/**
 * Deploy a contract behind a SystemContractProxy on Anvil, matching ZKsyncOS production layout.
 */
async function deployBehindSystemProxy(
  provider: ethers.providers.JsonRpcProvider,
  systemAddress: string,
  implBytecode: string,
  deployedBytecodeInfo: string
): Promise<void> {
  // Derive the implementation address the same way L2GenesisForceDeploymentsHelper does
  // on-chain: keccak256(bytes32(0) ++ bytecodeInfo).
  const [bytecodeInfo] = ethers.utils.defaultAbiCoder.decode(["bytes", "bytes"], deployedBytecodeInfo);
  const implAddressHash = ethers.utils.keccak256(ethers.utils.concat([ethers.constants.HashZero, bytecodeInfo]));
  const implAddress = ethers.utils.getAddress("0x" + implAddressHash.slice(26));

  await provider.send("anvil_setCode", [implAddress, implBytecode]);
  await provider.send("anvil_setCode", [systemAddress, getBytecode("SystemContractProxy")]);
  await provider.send("anvil_setStorageAt", [
    systemAddress,
    EIP1967_ADMIN_SLOT,
    ethers.utils.hexZeroPad(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, 32),
  ]);
  await provider.send("anvil_setStorageAt", [
    systemAddress,
    EIP1967_IMPL_SLOT,
    ethers.utils.hexZeroPad(implAddress, 32),
  ]);
}

// ── Calldata decoding ────────────────────────────────────────────────

/** Decoded force deployment entry with upgrade type metadata. */
export interface ForceDeployEntry {
  address: string;
  upgradeType: number; // ContractUpgradeType enum value
  deployedBytecodeInfo?: string;
}

/** Decode the ComplexUpgrader calldata (any variant) into its components. */
export function decodeUpgradeTxData(upgradeTxData: string): {
  forceDeployEntries: ForceDeployEntry[];
  delegateTo: string;
  innerCalldata: string;
} {
  const selector = upgradeTxData.slice(0, 10);
  const payload = "0x" + upgradeTxData.slice(10);
  const abiCoder = ethers.utils.defaultAbiCoder;

  if (selector === SELECTORS.eraForceDeployAndUpgrade) {
    const [deployments, delegateTo, innerCalldata] = abiCoder.decode(
      ["tuple(bytes32,address,bool,uint256,bytes)[]", "address", "bytes"],
      payload
    );
    const entries: ForceDeployEntry[] = deployments.map((fd: { 1: string }) => ({
      address: fd[1],
      upgradeType: UPGRADE_TYPE_ERA_FORCE_DEPLOYMENT,
    }));
    return { forceDeployEntries: entries, delegateTo, innerCalldata };
  }

  if (selector === SELECTORS.zkosForceDeployAndUpgradeUniversal) {
    const [deployments, delegateTo, innerCalldata] = abiCoder.decode(
      ["tuple(uint8,bytes,address)[]", "address", "bytes"],
      payload
    );
    const entries: ForceDeployEntry[] = deployments.map((fd: { 0: number; 1: string; 2: string }) => ({
      address: fd[2],
      upgradeType: fd[0],
      deployedBytecodeInfo: fd[1],
    }));
    return { forceDeployEntries: entries, delegateTo, innerCalldata };
  }

  throw new Error(`Unknown ComplexUpgrader selector: ${selector}`);
}

/** Build the address→contract map for the given VM type. */
function buildAddressToContract(isZKsyncOS: boolean): ReadonlyMap<string, ContractName> {
  const entries: Array<[string, ContractName]> = [
    [L2_MESSAGE_ROOT_ADDR.toLowerCase(), "L2MessageRoot"],
    [L2_BRIDGEHUB_ADDR.toLowerCase(), "L2Bridgehub"],
    [L2_ASSET_ROUTER_ADDR.toLowerCase(), "L2AssetRouter"],
    [L2_NATIVE_TOKEN_VAULT_ADDR.toLowerCase(), "L2NativeTokenVault"],
    [L2_CHAIN_ASSET_HANDLER_ADDR.toLowerCase(), "L2ChainAssetHandler"],
    [L2_ASSET_TRACKER_ADDR.toLowerCase(), "L2AssetTracker"],
    [INTEROP_CENTER_ADDR.toLowerCase(), "InteropCenter"],
    [INTEROP_ATTRIBUTE_PARSER_ADDR.toLowerCase(), "InteropAttributeParser"],
    [L2_INTEROP_HANDLER_ADDR.toLowerCase(), "L2InteropHandler"],
    [L2_BASE_TOKEN_HOLDER_ADDR.toLowerCase(), "BaseTokenHolder"],
    [L2_WRAPPED_BASE_TOKEN_IMPL_ADDR.toLowerCase(), "L2WrappedBaseToken"],
    [L2_MESSAGE_VERIFICATION_ADDR.toLowerCase(), "L2MessageVerification"],
    [L2_INTEROP_ROOT_STORAGE_ADDR.toLowerCase(), "L2InteropRootStorage"],
  ];
  if (isZKsyncOS) {
    // Keep this block in sync with SystemContractsProcessing's getFixedAddressCoreContracts /
    // getSystemProxyUpgradeContracts: every appended L2EcosystemContract member with a
    // fixed address rides the derived force-deployment list and needs a row here.
    entries.push(
      [L2_INTEROP_COMMITMENT_TREE_ADDR.toLowerCase(), "L2InteropCommitmentTree"],
      [L2_ATOMIC_FLOW_MANAGER_ADDR.toLowerCase(), "AtomicFlowManager"],
      [L2_BASE_TOKEN_ADDR.toLowerCase(), "L2BaseToken"],
      [L2_TO_L1_MESSENGER_ADDR.toLowerCase(), "L1Messenger"],
      [SYSTEM_CONTEXT_ADDR.toLowerCase(), "SystemContext"],
      [L2_COMPLEX_UPGRADER_ADDR.toLowerCase(), "L2ComplexUpgrader"],
      [L2_CONTRACT_DEPLOYER_ADDR.toLowerCase(), "ContractDeployer"],
      // The removed v31 GWAssetTracker: upgrades swap its proxy's implementation for EmptyContract.
      [L2_REMOVED_GW_ASSET_TRACKER_ADDR.toLowerCase(), "EmptyContract"]
    );
  }
  return new Map(entries);
}

// ── Verification ─────────────────────────────────────────────────────

async function verifyL2UpgradeResult(l2Provider: ethers.providers.JsonRpcProvider, chainId: number): Promise<void> {
  const assetTracker = new ethers.Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Provider);

  const l1ChainId = await assetTracker.L1_CHAIN_ID();
  if (!l1ChainId.eq(runtimeConfig.l1ChainId)) {
    throw new Error(`Chain ${chainId}: L2AssetTracker.L1_CHAIN_ID = ${l1ChainId}, expected ${runtimeConfig.l1ChainId}`);
  }

  const baseTokenAssetId = await assetTracker.BASE_TOKEN_ASSET_ID();
  if (!(await assetTracker.isAssetRegistered(baseTokenAssetId))) {
    throw new Error(`Chain ${chainId}: base token bookkeeping not initialized after L2 upgrade`);
  }
}

export async function verifyProtocolVersions(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  expectedProtocolVersion: string
): Promise<void> {
  const expectedVersion = ethers.BigNumber.from(expectedProtocolVersion);
  for (const chain of chains) {
    const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
    const version = await diamond.getProtocolVersion();
    if (!version.eq(expectedVersion)) {
      throw new Error(
        `Chain ${chain.chainId}: protocol version ${version.toHexString()}, expected ${expectedVersion.toHexString()}`
      );
    }
  }
}

/**
 * The CTM's interop fee manager must be deployed, on this bridgehub and switched off with ether as the fee token: the
 * Executor charges through it.
 */
export async function verifyInteropFeeManager(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  bridgehubAddr: string
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), provider);
  const feeManagerAddr: string = await ctm.L1_INTEROP_FEE_MANAGER();
  if ((await provider.getCode(feeManagerAddr)) === "0x") {
    throw new Error(`CTM ${ctmAddr}: no interop fee manager deployed at ${feeManagerAddr}`);
  }
  const feeManager = new ethers.Contract(feeManagerAddr, getAbi("L1InteropFeeManager"), provider);
  const feeManagerBridgehub: string = await feeManager.BRIDGE_HUB();
  if (feeManagerBridgehub.toLowerCase() !== bridgehubAddr.toLowerCase()) {
    throw new Error(
      `Interop fee manager ${feeManagerAddr} is on bridgehub ${feeManagerBridgehub}, expected ${bridgehubAddr}`
    );
  }
  const feePerUnit: ethers.BigNumber = await feeManager.feePerUnit();
  if (!feePerUnit.isZero()) {
    throw new Error(`Interop fee manager ${feeManagerAddr} is switched on: feePerUnit = ${feePerUnit.toString()}`);
  }
  const feeToken: string = await feeManager.feeToken();
  if (feeToken.toLowerCase() !== ETH_TOKEN_ADDRESS.toLowerCase()) {
    throw new Error(`Interop fee manager ${feeManagerAddr} charges in ${feeToken}, expected ether`);
  }
}

/**
 * Post-upgrade CTM-side assertions for the bootstrap edge: the version bumped, the whole CTM
 * domain (CTM + its ProxyAdmin) landed under ONE new authority that is not governance (the
 * bound `CTMUpgradeExecutor`), the genesis release the migration names is pinned, and the commit
 * has the legacy cut-taking shape (hash written, no transition registered).
 */
async function verifyCtmEndState(
  provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  governance: string,
  params: { oldVersion: ethers.BigNumber; expectedProtocolVersion: string; migrationAddr: string }
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), provider);
  const ownable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), provider);

  const version: ethers.BigNumber = await ctm.protocolVersion();
  if (!version.eq(ethers.BigNumber.from(params.expectedProtocolVersion))) {
    throw new Error(`CTM protocol version ${version.toHexString()}, expected ${params.expectedProtocolVersion}`);
  }

  const ctmOwner: string = await ownable.owner();
  const proxyAdminAddr = await readProxyAdmin(provider, ctmAddr);
  const proxyAdmin = new ethers.Contract(proxyAdminAddr, getAbi("ProxyAdmin"), provider);
  const proxyAdminOwner: string = await proxyAdmin.owner();
  if (ctmOwner.toLowerCase() === governance.toLowerCase()) {
    throw new Error("CTM ownership did not leave governance — the bootstrap handover did not complete");
  }
  if (ctmOwner.toLowerCase() !== proxyAdminOwner.toLowerCase()) {
    throw new Error(
      `CTM domain authority is split: CTM owner ${ctmOwner}, ProxyAdmin owner ${proxyAdminOwner} — ` +
        "both must be the bound CTMUpgradeExecutor"
    );
  }

  // The CTM's `releaseCodehash` anchor was removed: a runtime codehash cannot prove the release's
  // audited constructor ran. What stays checkable is that the CTM points at the very release the
  // pipeline pinned — read off the migration OBJECT, the way the engine reads it — and that the
  // pointer names code rather than an empty address.
  const release: string = await ctm.currentRelease();
  if (release === ethers.constants.AddressZero) {
    throw new Error("currentRelease not pinned after the bootstrap edge");
  }
  const migration = new ethers.Contract(params.migrationAddr, getAbi("RegistryBootstrapMigration"), provider);
  const pinnedRelease: string = (await migration.getManifest()).currentRelease;
  if (release.toLowerCase() !== pinnedRelease.toLowerCase()) {
    throw new Error(`CTM currentRelease ${release} is not the release the migration pins (${pinnedRelease})`);
  }
  if (ethers.utils.hexDataLength(await provider.getCode(release)) === 0) {
    throw new Error(`CTM currentRelease ${release} has no code`);
  }

  const cutHash: string = await ctm.upgradeCutHash(params.oldVersion);
  if (cutHash === ethers.constants.HashZero) {
    throw new Error("the bootstrap edge must commit the legacy cut hash for the departing version");
  }
  const committedTransition: string = await ctm.upgradeTransition(params.oldVersion);
  if (committedTransition !== ethers.constants.AddressZero) {
    throw new Error("the bootstrap edge must not register a transition");
  }
  console.log(`  ✓ CTM at ${params.expectedProtocolVersion}, domain under executor ${ctmOwner}, release ${release}`);
}

// ── Ownership helpers ────────────────────────────────────────────────

async function transferOwnership2Step(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  governanceAddr: string,
  contractAddr: string
): Promise<void> {
  const contract = new ethers.Contract(contractAddr, getAbi("Ownable2Step"), provider);
  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) return;
  if (currentOwner.toLowerCase() !== defaultSigner.address.toLowerCase()) {
    throw new Error(`Expected deployer to own ${contractAddr}, found ${currentOwner}`);
  }
  await transferOwnable2Step(provider, contractAddr, getAbi("Ownable2Step"), currentOwner, governanceAddr);
}

// ── TOML config helpers ──────────────────────────────────────────────

function replaceTomlStringValue(contents: string, key: string, value: string): string {
  // eslint-disable-next-line no-useless-escape
  const pattern = new RegExp(`^(${key}\\s*=\\s*\").*(\")$`, "m");
  return pattern.test(contents) ? contents.replace(pattern, `$1${value}$2`) : contents;
}

function replaceTomlBareValue(contents: string, key: string, value: string): string {
  const pattern = new RegExp(`^(${key}\\s*=\\s*).*$`, "m");
  return pattern.test(contents) ? contents.replace(pattern, `$1${value}`) : `${key} = ${value}\n${contents}`;
}

export function prepareUpgradeHarnessInputs(
  scenario: PipelineUpgradeScenario,
  state: {
    l1Addresses: { bridgehub: string; governance: string };
    ctmAddresses: { chainTypeManager: string };
    chainAddresses: Array<{ chainId: number }>;
    /** The live EIP-7702 checker, when a previous prepare reported one. */
    eip7702Checker?: string;
  }
): {
  envVars: Record<string, string>;
  ecosystemOutputPath: string;
  bridgehubAddress: string;
  protocolOpsOutDir: string;
  upgradeInputArg: string;
  rollupDaManagerAddress: string;
  create2FactorySalt: string;
  isZKsyncOS: boolean;
  ctmProxyAddress: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${scenario.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${scenario.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${scenario.label}-upgrade-input.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${scenario.label}-upgrade-ecosystem.toml`);
  const protocolOpsOutDir = path.join(tempDir, "protocol-ops");

  const primaryChainId = state.chainAddresses[0]?.chainId;
  if (!primaryChainId) throw new Error(`No chains loaded for ${scenario.label}`);

  let permanentValues = fs.readFileSync(path.join(l1ContractsDir, scenario.permanentValuesTemplatePath), "utf8");
  permanentValues = replaceTomlBareValue(permanentValues, "era_chain_id", String(primaryChainId));
  permanentValues = replaceTomlStringValue(permanentValues, "bridgehub_proxy_addr", state.l1Addresses.bridgehub);
  permanentValues = replaceTomlStringValue(permanentValues, "ctm_proxy_addr", state.ctmAddresses.chainTypeManager);
  // Every prepare deploys under a salt of its own, as production rotates `[contracts]
  // create2_factory_salt` per release: a hop redeploying an implementation under an earlier
  // prepare's salt lands on the address that prepare already installed, and its row is inert.
  if (!/^create2_factory_salt\s*=/m.test(permanentValues)) {
    throw new Error(`${scenario.permanentValuesTemplatePath} has no create2_factory_salt to rotate`);
  }
  permanentValues = replaceTomlStringValue(
    permanentValues,
    "create2_factory_salt",
    ethers.utils.id(`anvil-interop upgrade ${scenario.label}`)
  );
  fs.writeFileSync(permanentValuesPath, permanentValues);

  let upgradeInput = fs.readFileSync(path.join(l1ContractsDir, scenario.upgradeInputTemplatePath), "utf8");
  upgradeInput = replaceTomlBareValue(upgradeInput, "era_chain_id", String(primaryChainId));
  upgradeInput = replaceTomlStringValue(upgradeInput, "bridgehub_proxy_address", state.l1Addresses.bridgehub);
  upgradeInput = replaceTomlStringValue(upgradeInput, "owner_address", state.l1Addresses.governance);
  upgradeInput = replaceTomlBareValue(upgradeInput, "sample_chain_id", String(primaryChainId));
  if (state.eip7702Checker) {
    // Exactly what a production env file carries forward from the previous prepare's output; see
    // `readReportedEip7702Checker`.
    upgradeInput = upgradeInput.replace(/^\[contracts\]$/m, `[contracts]\neip7702_checker = "${state.eip7702Checker}"`);
  }
  fs.writeFileSync(upgradeInputPath, upgradeInput);

  const permanentValuesToml = parseToml(permanentValues) as {
    ctm_contracts?: {
      rollup_da_manager?: string;
    };
    permanent_contracts?: {
      create2_factory_salt?: string;
    };
  };

  return {
    envVars: {
      PERMANENT_VALUES_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, permanentValuesPath)}`,
      UPGRADE_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
      UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
    },
    ecosystemOutputPath,
    bridgehubAddress: state.l1Addresses.bridgehub,
    protocolOpsOutDir,
    upgradeInputArg: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
    rollupDaManagerAddress: permanentValuesToml.ctm_contracts?.rollup_da_manager ?? ethers.constants.AddressZero,
    create2FactorySalt: permanentValuesToml.permanent_contracts?.create2_factory_salt ?? ethers.constants.HashZero,
    isZKsyncOS: scenario.isZKsyncOS,
    ctmProxyAddress: state.ctmAddresses.chainTypeManager,
    // Kept alongside the chains: debugging a run needs the INPUTS that produced it (the
    // merged prepare TOML is also what `protocol-ops ecosystem verify-bootstrap` consumes),
    // and they are worthless once the chains they describe are gone.
    cleanup: () => {
      if (process.env.ANVIL_INTEROP_KEEP_CHAINS === "1") {
        console.log(`  ℹ kept prepare inputs for debugging: ${tempDir}`);
        return;
      }
      fs.rmSync(tempDir, { recursive: true, force: true });
    },
  };
}
