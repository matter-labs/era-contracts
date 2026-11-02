/**
 * Version-independent pipeline upgrade test runner.
 *
 * Replays REAL protocol upgrades — the production protocol-ops toolchain driving the version's
 * actual forge prepare scripts — against pre-generated anvil chain states of the departing version:
 *
 *   1. Load the frozen chain states (`chain-states/<stateVersion>`) and select target chains.
 *      Settle one batch on each (see batch-settlement.ts): the fixtures' chains never settled one,
 *      so their genesis upgrade is still pending and would block the upgrade.
 *   2. Give the fixture a production ecosystem's authority (it leaves the core contracts and both
 *      upgrade executors with the deployer) and put each target chain under a ChainAdmin.
 *   3. Run the scenario's registry-driven hops in order, each departing from the state the previous
 *      one left (see runRecurringHop): the release's own edge first, as protocol-ops prepares it.
 *
 * The frozen states keep the deployment's contracts but not its outputs, so the harness rebuilds
 * what a reviewer reads from them — the executors' construction record, the live EIP-7702 checker
 * and the ZK token asset id the live release pins — from the anvil deployment's own config.
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
  DETERMINISTIC_CREATE2_FACTORY_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETHEREUM_L1_TX_GAS_LIMIT,
} from "../core/const";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { BatchSettler } from "./batch-settlement";
import type { GenesisBatchParams } from "./batch-settlement";
import { transferOwnable2Step } from "./harness-shims";
import {
  assertCtmTransitionApplied,
  assertLegsApplied,
  discoverDomainExecutors,
  findLegExecution,
  readProxyAdmin,
  keepL1SettledChains,
  selectUpgradeChains,
  snapshotProxyUpgradeLegs,
  traceFailedTx,
  upgradeLegCall,
  upgradeLegSelectors,
} from "./upgrade-test-utils";
import type { GovernanceCall, MergedGovernanceOutput } from "./governance-bundle";
import { assertBundleIs, assertRegistryHopBundle, upgradeLegsOf } from "./governance-bundle";
import { l1GasOverrides, recordL1TransactionGas } from "./l1-transaction-gas";
import { createProvider, impersonateAndRun } from "../core/utils";
import type { ChainRole } from "../core/types";

// ── Constants ────────────────────────────────────────────────────────

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");
const contractsRootDir = path.resolve(l1ContractsDir, "..");

// What `verify-package` prints for the outcomes the harness holds it to.
const UNCONSULTED_RECORDS_REPORT = "recorded deployment(s) no check of this review consulted";
// Upper bound on a verifier report the harness reads back.
const PROTOCOL_OPS_REPORT_MAX_BYTES = 64 * 1024 * 1024;
// The `verify-package` errors an anvil fixture causes by construction, and nothing else may: its states are built
// without CBOR metadata, so the L2 code a release keeps from them is never the committed genesis image's, and its
// ZiSK side runs a stub Plonk backend rather than the pinned one.
const FIXTURE_REVIEW_ERRORS = [
  /^the release the transition installs: genesis image: /,
  / which is not the pinned ZiSK Plonk backend /,
];

// ── Public types ─────────────────────────────────────────────────────

export type PipelineUpgradeScenario = {
  label: string;
  /** chain-states/<stateVersion> to boot from — the FROZEN departing-version fixture. */
  stateVersion: string;
  permanentValuesTemplatePath: string;
  targetRoles: ChainRole[];
  /** Genesis parameters of the CTM the `stateVersion` chains were created from (see batch-settlement.ts). */
  sourceGenesis: GenesisBatchParams;
  /** The registry-driven hops run on the target chains, in order (see runRecurringHop). */
  hops: RecurringUpgradeHop[];
};

export type RecurringUpgradeHop = {
  label: string;
  upgradeInputTemplatePath: string;
  /** Protocol version the chains must report once the hop has been applied. */
  expectedProtocolVersion: string;
  /**
   * Forge script targets driven by protocol-ops (`--core-script-path` / `--ctm-script-path`). Omitted,
   * protocol-ops prepares with its defaults: the current release's scripts.
   */
  coreScriptPath?: string;
  ctmScriptPath?: string;
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
   * "previous upgrade finalized" check when the minor version does not change. Before every other
   * hop a batch carrying it is settled first.
   */
  keepsPendingL2Upgrade?: boolean;
};

// ── Main entry point ─────────────────────────────────────────────────

export async function runPipelineUpgradeScenario(scenario: PipelineUpgradeScenario): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const harnessDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-${scenario.label}`);

  try {
    // ── Load pre-generated chain states ──
    const stateDir = path.join(anvilInteropDir, "chain-states", scenario.stateVersion);
    if (!fs.existsSync(path.join(stateDir, "addresses.json"))) {
      throw new Error(`${scenario.stateVersion} chain states not found. Generate them first.`);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, stateDir);
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) {
      throw new Error("L1 chain not started");
    }
    const l1Provider = createProvider(l1Chain.rpcUrl);
    const upgradeChainAddresses = await keepL1SettledChains(
      l1Provider,
      l1Addresses.bridgehub,
      selectUpgradeChains(chainAddresses, chains.config, scenario.targetRoles)
    );
    if (upgradeChainAddresses.length === 0) {
      throw new Error(`No chains matched upgrade roles ${scenario.targetRoles.join(", ")} for ${scenario.label}`);
    }
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

    // ── Settle the fixture chains' genesis upgrade batch ──
    // Before the ownership handover: the default account is still the chains' admin here.
    console.log("\n── Settling a batch on each target chain ──");
    const settler = await BatchSettler.create(defaultSigner, upgradeChainAddresses, scenario.sourceGenesis);
    await settler.settleNextBatch(upgradeChainAddresses);

    // ── Transfer L1 contract ownership to governance ──
    console.log("\n── Preparing L1 ownership for upgrade ──");
    const executors = await discoverDomainExecutors(
      l1Provider,
      ctmAddresses.chainTypeManager,
      await readProxyAdmin(l1Provider, l1Addresses.messageRoot)
    );
    await transferL1Ownership(l1Provider, defaultSigner, l1Addresses, executors);

    // ── Deploy ChainAdmin for each upgrade target ──
    console.log("\n── Deploying temporary ChainAdminOwnable contracts ──");
    await deployChainAdmins(l1Provider, defaultSigner, upgradeChainAddresses);

    // ── What a reviewer reads from the deployment's outputs, rebuilt from its config ──
    fs.mkdirSync(harnessDir, { recursive: true });
    const deploymentSalt = readFixtureDeploymentSalt();
    const executorRecords = path.join(harnessDir, "fixture-executor-records.toml");
    await writeFixtureExecutorRecords(l1Provider, executorRecords, executors, deploymentSalt);
    const reviewedBuildHashes = path.join(harnessDir, "reviewed-build-hashes.json");
    writeReviewedBuildHashes(reviewedBuildHashes);
    const zkTokenAssetId: string = JSON.parse(fs.readFileSync(path.join(stateDir, "addresses.json"), "utf8")).zkToken
      .assetId;

    // Each hop departs from the state the previous one left, and carries the EIP-7702 checker
    // forward the way a production env file does.
    let eip7702Checker: string | undefined = await fixtureEip7702Checker(l1Provider, deploymentSalt);
    for (const hop of scenario.hops) {
      eip7702Checker = await runRecurringHop(scenario, hop, {
        l1Provider,
        rpcUrl: l1Chain.rpcUrl,
        l1Addresses,
        ctmAddresses,
        upgradeChainAddresses,
        settler,
        eip7702Checker,
        executorRecords,
        reviewedBuildHashes,
        zkTokenAssetId,
      });
    }
  } finally {
    if (keepChains) {
      console.log(`  ℹ kept harness inputs for debugging: ${harnessDir}`);
    } else {
      fs.rmSync(harnessDir, { recursive: true, force: true });
      await anvilManager.stopAll();
    }
  }
}

/** The CREATE2 salt the anvil deployment ran with (`DeployL1CoreContracts`, `DeployCTM`). */
function readFixtureDeploymentSalt(): string {
  const permanentValues = parseToml(
    fs.readFileSync(path.join(anvilInteropDir, "config", "permanent-values.toml"), "utf8")
  ) as { permanent_contracts: { create2_factory_salt: string } };
  return permanentValues.permanent_contracts.create2_factory_salt;
}

/**
 * The `[upgrade_executors]` record of the fixture's executors, as the deployment that built them writes it:
 * constructed for the deployer under the deployment's salt, over the immutables each executor serves.
 * `verify-package` re-derives each executor from it, so a wrong record fails the review.
 */
async function writeFixtureExecutorRecords(
  provider: ethers.providers.JsonRpcProvider,
  outputPath: string,
  executors: { coreExecutor: string; ctmExecutor: string },
  salt: string
): Promise<void> {
  const core = new ethers.Contract(executors.coreExecutor, getAbi("CoreUpgradeExecutor"), provider);
  const ctm = new ethers.Contract(executors.ctmExecutor, getAbi("CTMUpgradeExecutor"), provider);
  const record = [
    "[upgrade_executors.core_executor]",
    `address = "${executors.coreExecutor}"`,
    `create2_salt = "${salt}"`,
    `initial_owner = "${ANVIL_DEFAULT_ACCOUNT_ADDR}"`,
    `proxy_admin = "${await core.PROXY_ADMIN()}"`,
    "",
    "[upgrade_executors.ctm_executor]",
    `address = "${executors.ctmExecutor}"`,
    `create2_salt = "${salt}"`,
    `initial_owner = "${ANVIL_DEFAULT_ACCOUNT_ADDR}"`,
    `chain_type_manager = "${await ctm.CHAIN_TYPE_MANAGER()}"`,
    `ctm_proxy_admin = "${await ctm.CTM_PROXY_ADMIN()}"`,
    "",
  ];
  fs.writeFileSync(outputPath, record.join("\n"));
}

/** The CTM's EIP-7702 checker: argument-less, so CREATE2 placed it from the deployment's salt alone. */
async function fixtureEip7702Checker(provider: ethers.providers.JsonRpcProvider, salt: string): Promise<string> {
  const checker = ethers.utils.getCreate2Address(
    DETERMINISTIC_CREATE2_FACTORY_ADDR,
    salt,
    ethers.utils.keccak256(getCreationBytecode("EIP7702Checker"))
  );
  if ((await provider.getCode(checker)) === "0x") {
    throw new Error(
      `no EIP-7702 checker at ${checker}, where the fixture's deployment placed it: build l1-contracts with ` +
        "FOUNDRY_PROFILE=anvil-interop, as the states were"
    );
  }
  return checker;
}

// ── Registry-driven hop ───────────────────────────────────────────────

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
 * One registry-driven hop on the target chains — the production shape of every upgrade after v35,
 * driven by the real toolchain end to end:
 *
 *   1. protocol-ops `upgrade-prepare-all` runs the hop's prepares: the core prepare
 *      deploys the ecosystem implementations the hop changes and pins them in a Core-domain
 *      `ProxyUpgradeTransition`; the CTM prepare deploys the release and the `CTMTransition` (and a
 *      CTM-domain `ProxyUpgradeTransition` when a CTM-domain proxy changes).
 *   2. The merged `ecosystem.toml` is asserted to carry exactly the legs those objects call for —
 *      `applyL1Upgrade` -> `applyInfrastructureUpgrade` -> `applyCTMUpgrade`, absent legs left
 *      out — on the executors found through custody (the ecosystem ProxyAdmin's owner, the CTM's
 *      owner), with no other call and no `external_actions` at all: the tooling claim, checked on
 *      the artifact. `protocol-ops ecosystem verify-package` must pass on it.
 *   3. The governance replay executes it; each chain then crosses through the cut-READING
 *      `upgradeChainFromVersion` as its own admin (no cut is handed over).
 *   4. End state: one transaction emitted each leg's domain event once, in leg order; each row
 *      object's proxies run their `implNew`, with `ProxyImplementationUpgraded` exactly for the
 *      rows that moved; chains and CTM at the new version, the transition committed for the
 *      departing version, the CTM on the transition's release, and the CTM domain still held by
 *      the CTM executor (`assertCtmTransitionApplied`).
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
    settler: BatchSettler;
    /** The live EIP-7702 checker, carried forward from the fixture or the previous hop's prepare. */
    eip7702Checker?: string;
    /** The records of the executors every hop runs through (see `writeFixtureExecutorRecords`). */
    executorRecords: string;
    /** The hashes of the build the scenario deploys from (see `writeReviewedBuildHashes`). */
    reviewedBuildHashes: string;
    /** The ZK token asset id the live release pins, which the hop's releases keep. */
    zkTokenAssetId: string;
  }
): Promise<string | undefined> {
  console.log(`\n══ Registry-driven hop: ${hop.label} ══`);
  const { l1Provider, upgradeChainAddresses } = ctx;
  const ctm = new ethers.Contract(ctx.ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);
  const oldVersion: ethers.BigNumber = await ctm.protocolVersion();
  console.log(`  departing protocol version: ${oldVersion.toHexString()}`);

  // The previous hop's L2 leg is pending until a batch carrying it is executed, which blocks a
  // MINOR upgrade. A patch hop deliberately keeps it, to prove it survives.
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
    await ctx.settler.settleNextBatch(upgradeChainAddresses);
  }

  const inputs = prepareUpgradeHarnessInputs(scenario, hop, {
    l1Addresses: ctx.l1Addresses,
    ctmAddresses: ctx.ctmAddresses,
    chainAddresses: upgradeChainAddresses,
    eip7702Checker: ctx.eip7702Checker,
  });
  try {
    console.log("\n── Preparing the registry-driven upgrade via protocol-ops ──");
    await runEcosystemUpgradeScripts({
      rpcUrl: ctx.rpcUrl,
      hop,
      upgradeHarnessInputs: inputs,
      zkTokenAssetId: ctx.zkTokenAssetId,
      executeBundles: true,
    });
    const mergedEcosystemToml = path.join(inputs.protocolOpsOutDir, "ecosystem.toml");
    if (!fs.existsSync(mergedEcosystemToml)) {
      throw new Error(`Merged ecosystem TOML not emitted by upgrade-prepare-all: ${mergedEcosystemToml}`);
    }
    const merged = parseToml(fs.readFileSync(mergedEcosystemToml, "utf8")) as MergedGovernanceOutput & {
      core: {
        registry?: { core_transition_addr?: string; core_upgrade_executor_addr?: string };
      };
      ctms: {
        zksync_os: {
          registry?: {
            ctm_transition_addr?: string;
            ctm_infrastructure_transition_addr?: string;
            ctm_upgrade_executor_addr?: string;
            bootstrap_migration_addr?: string;
          };
        };
      };
    };
    const coreRegistry = merged.core.registry ?? {};
    const ctmRegistry = merged.ctms.zksync_os.registry ?? {};
    const bootstrapMigration = ctmRegistry.bootstrap_migration_addr ?? ethers.constants.AddressZero;
    if (bootstrapMigration !== ethers.constants.AddressZero) {
      throw new Error(`a recurring hop must not deploy a bootstrap migration (got ${bootstrapMigration})`);
    }
    const reportedLegs = upgradeLegsOf({
      coreTransition: coreRegistry.core_transition_addr,
      coreExecutor: coreRegistry.core_upgrade_executor_addr,
      ctmInfrastructureTransition: ctmRegistry.ctm_infrastructure_transition_addr,
      ctmTransition: ctmRegistry.ctm_transition_addr,
      ctmExecutor: ctmRegistry.ctm_upgrade_executor_addr,
    });
    const transitionLeg = reportedLegs.find((leg) => leg.kind === "ctmTransition");
    if (!transitionLeg) {
      throw new Error(`hop ${hop.label} moves the protocol version, but the CTM prepare reported no transition`);
    }
    const transitionAddr = transitionLeg.object;
    const executorAddr = transitionLeg.executor;

    // The executors the legs must target, found through custody rather than taken from the prepare.
    const executors = await discoverDomainExecutors(
      l1Provider,
      ctx.ctmAddresses.chainTypeManager,
      await readProxyAdmin(l1Provider, ctx.l1Addresses.messageRoot)
    );
    for (const leg of reportedLegs) {
      const custodian = leg.kind === "core" ? executors.coreExecutor : executors.ctmExecutor;
      if (leg.executor.toLowerCase() !== custodian.toLowerCase()) {
        throw new Error(`the prepare names ${leg.executor} for the ${leg.kind} leg, but custody names ${custodian}`);
      }
    }
    for (const leg of reportedLegs) {
      console.log(`  ${leg.kind.padEnd(18)} ${leg.object} via ${leg.executor}`);
    }

    // ── The tooling claim, checked on the artifact ──
    const legs = assertRegistryHopBundle(merged, upgradeLegSelectors(), reportedLegs);
    console.log(
      `  ✓ the merged bundle is exactly the ${legs.map((leg) => leg.kind).join(" -> ")} leg run, ` +
        "with no other call and no external actions"
    );

    verifyPackageAsReviewed({
      rpcUrl: ctx.rpcUrl,
      ecosystemToml: mergedEcosystemToml,
      governance: ctx.l1Addresses.governance,
      bridgehub: ctx.l1Addresses.bridgehub,
      zkTokenAssetId: ctx.zkTokenAssetId,
      reviewedBuildHashes: ctx.reviewedBuildHashes,
      executorRecords: [ctx.executorRecords],
    });

    const rowSnapshots = await snapshotProxyUpgradeLegs(l1Provider, reportedLegs);

    // ── Governance executes the bundle ──
    console.log("\n── Replaying the governance bundle via protocol-ops ──");
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
          signer.sendTransaction({ to: chain.diamondProxy, data, ...l1GasOverrides(10_000_000) }),
          `chain ${chain.chainId}: upgradeChainFromVersion(${oldVersion.toHexString()})`
        );
      });
      console.log(`  ✓ chain ${chain.chainId} crossed the registry-driven edge (cut read from the CTM)`);
    }

    // ── End state ──
    console.log("\n── Verifying the registry-driven end state ──");
    const execution = await findLegExecution(l1Provider, reportedLegs, replayFromBlock);
    // That transaction is the ecosystem Governance executing one operation of exactly the legs.
    const executionTx = await l1Provider.getTransaction(execution.transactionHash);
    if (executionTx.to?.toLowerCase() !== ctx.l1Addresses.governance.toLowerCase()) {
      throw new Error(
        `the legs ran in a transaction to ${executionTx.to}, not to governance ${ctx.l1Addresses.governance}`
      );
    }
    const governanceCall = new ethers.utils.Interface(getAbi("Governance")).parseTransaction(executionTx);
    if (governanceCall.name !== "execute") {
      throw new Error(`the legs ran in Governance.${governanceCall.name}, expected Governance.execute`);
    }
    const executedCalls: GovernanceCall[] = governanceCall.args[0].calls.map(
      (call: { target: string; value: ethers.BigNumber; data: string }) => ({
        target: call.target,
        value: call.value,
        data: call.data,
      })
    );
    assertBundleIs(executedCalls, reportedLegs.map(upgradeLegCall), "the operation Governance executed");
    const applied = await assertLegsApplied(l1Provider, execution, reportedLegs, rowSnapshots);
    const ctmExecutorIface = new ethers.utils.Interface(getAbi("CTMUpgradeExecutor"));
    const transitionAppliedLog = execution.logs.find(
      (log) =>
        log.address.toLowerCase() === executorAddr.toLowerCase() &&
        log.topics[0] === ctmExecutorIface.getEventTopic("CTMUpgradeApplied")
    );
    const transitionApplied = transitionAppliedLog && ctmExecutorIface.parseLog(transitionAppliedLog);
    if (
      !transitionApplied ||
      !transitionApplied.args.oldProtocolVersion.eq(oldVersion) ||
      !transitionApplied.args.newProtocolVersion.eq(ethers.BigNumber.from(hop.expectedProtocolVersion))
    ) {
      throw new Error(
        `CTMUpgradeApplied does not record the ${oldVersion.toHexString()} -> ${hop.expectedProtocolVersion} edge`
      );
    }
    console.log(
      `  ✓ one governance execution (${execution.transactionHash}) applied the ${legs.length} leg(s) in order: ` +
        `${applied.rows} row(s) at implNew, ${applied.swaps} swap(s) emitted`
    );
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses, hop.expectedProtocolVersion);
    const version: ethers.BigNumber = await ctm.protocolVersion();
    if (!version.eq(ethers.BigNumber.from(hop.expectedProtocolVersion))) {
      throw new Error(`CTM protocol version ${version.toHexString()}, expected ${hop.expectedProtocolVersion}`);
    }
    await assertCtmTransitionApplied(
      l1Provider,
      ctx.ctmAddresses.chainTypeManager,
      transitionAddr,
      oldVersion,
      executors.ctmExecutor
    );
    console.log(
      `  ✓ CTM commits ${transitionAddr} for ${oldVersion.toHexString()} and runs its release; ` +
        `domain held by ${executors.ctmExecutor}`
    );
    const transition = new ethers.Contract(transitionAddr, getAbi("ICTMTransition"), l1Provider);
    const newRelease: string = await transition.newRelease();
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
      `✅ Registry-driven hop ${hop.label} verified: one governance execution of ${legs.length} leg(s), ` +
        `chains at ${hop.expectedProtocolVersion}\n`
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
  await recordL1TransactionGas(provider, receipt, tx.gasLimit, {
    phase: "chain-upgrade",
    bundle: label,
    index: 1,
    target: tx.to!,
  });
  return receipt;
}

// ── L1 ownership & admin setup ───────────────────────────────────────

/**
 * Gives the fixture a production ecosystem's authority, which the anvil deployment partly leaves with the
 * deployer: governance owns the core contracts and both upgrade executors (the CTM domain stays with the CTM
 * executor).
 */
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
  executors: { coreExecutor: string; ctmExecutor: string }
): Promise<void> {
  const gov = l1Addresses.governance;
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.bridgehub);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1SharedBridge);
  await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NativeTokenVault);
  // A production ecosystem hands the nullifier to governance at deploy time; the fixtures leave
  // it with the deployer.
  if (l1Addresses.l1NullifierProxy) {
    await transferOwnership2Step(provider, defaultSigner, gov, l1Addresses.l1NullifierProxy);
  }
  await transferOwnership2Step(provider, defaultSigner, gov, executors.coreExecutor);
  await transferOwnership2Step(provider, defaultSigner, gov, executors.ctmExecutor);
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

/** {@link runProtocolOps}, echoing what it printed on stdout and returning it with the exit status. */
function runProtocolOpsForReport(args: string[]): { report: string; status: number | null } {
  const result = spawnSync("./protocol-ops.sh", args, {
    cwd: contractsRootDir,
    stdio: ["inherit", "pipe", "inherit"],
    encoding: "utf8",
    maxBuffer: PROTOCOL_OPS_REPORT_MAX_BYTES,
    env: {
      ...process.env,
      PROTOCOL_CONTRACTS_ROOT: contractsRootDir,
    },
  });
  process.stdout.write(result.stdout ?? "");
  if (result.error) {
    throw result.error;
  }
  return { report: result.stdout, status: result.status };
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
 * `protocol-ops ecosystem verify-package` on a merged prepare output, run the way a reviewer runs it
 * before governance signs: against the live L1, the reviewed governance owner and the `local` env's
 * permanent values. The fixture's Bridgehub and ZK token are not the ones `local` names, so they are the
 * reviewer's `--expected-bridgehub` and `--expected-zk-token-asset-id`. Throws when the verifier reports
 * an error other than the ones the fixture causes ({@link FIXTURE_REVIEW_ERRORS}), or a construction
 * record no check consulted (every deployment of these prepares is a member the package installs, so an
 * unconsulted one means a check was skipped).
 */
function verifyPackageAsReviewed(params: {
  rpcUrl: string;
  ecosystemToml: string;
  governance: string;
  bridgehub: string;
  zkTokenAssetId: string;
  reviewedBuildHashes: string;
  /** Files carrying `[upgrade_executors]` records the package itself does not carry. */
  executorRecords: string[];
}): void {
  console.log("\n── verify-package: reviewing the package before governance replays it ──");
  const { report, status } = runProtocolOpsForReport([
    "ecosystem",
    "verify-package",
    "--ecosystem-toml",
    params.ecosystemToml,
    "--l1-rpc-url",
    params.rpcUrl,
    "--expected-governance-owner",
    params.governance,
    "--env",
    "local",
    "--expected-bridgehub",
    params.bridgehub,
    "--expected-zk-token-asset-id",
    params.zkTokenAssetId,
    "--contract-hashes",
    params.reviewedBuildHashes,
    ...params.executorRecords.flatMap((record) => ["--executor-record", record]),
  ]);
  if (report.includes(UNCONSULTED_RECORDS_REPORT)) {
    throw new Error("verify-package left construction records unconsulted (see its report above)");
  }
  // eslint-disable-next-line no-control-regex
  const errors = report.replace(/\x1b\[[0-9;]*m/g, "").match(/^\[ERROR\]:\s*.*$/gm) ?? [];
  const unexpected = errors
    .map((line) => line.replace(/^\[ERROR\]:\s*/, ""))
    .filter((error) => !FIXTURE_REVIEW_ERRORS.some((pattern) => pattern.test(error)));
  if (unexpected.length !== 0 || (status !== 0 && errors.length === 0)) {
    throw new Error(`verify-package failed (see its report above):\n${unexpected.join("\n")}`);
  }
  if (errors.length !== 0) {
    console.log(`  ℹ ${errors.length} verify-package error(s) are the anvil fixture's own (genesis image, ZiSK stub)`);
  }
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
          ...l1GasOverrides(ETHEREUM_L1_TX_GAS_LIMIT),
        });
        const receipt = await tx.wait();
        if (receipt.status !== 1) {
          const trace = await traceFailedTx(provider, receipt.transactionHash);
          throw new Error(
            `Safe bundle ${path.basename(bundle.file)} tx ${i + 1}/${transactions.length} reverted:\n${trace}`
          );
        }
        await recordL1TransactionGas(provider, receipt, tx.gasLimit, {
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
  hop: RecurringUpgradeHop;
  upgradeHarnessInputs: UpgradeHarnessInputs;
  /** The asset id the live release pins: the fixture's ZK token is not the one the local network names. */
  zkTokenAssetId: string;
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
      ...(params.upgradeHarnessInputs.rollupDaManagerAddress
        ? ["--rollup-da-manager-address", params.upgradeHarnessInputs.rollupDaManagerAddress]
        : []),
      "--create2-factory-salt",
      params.upgradeHarnessInputs.create2FactorySalt,
      "--upgrade-input-path",
      params.upgradeHarnessInputs.upgradeInputArg,
      "--zk-token-asset-id",
      params.zkTokenAssetId,
      ...(params.hop.coreScriptPath ? ["--core-script-path", params.hop.coreScriptPath] : []),
      ...(params.hop.ctmScriptPath ? ["--ctm-script-path", params.hop.ctmScriptPath] : []),
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

/** `address`, unless it is absent or the zero address a template leaves for "unset". */
function nonZeroAddress(address: string | undefined): string | undefined {
  return address && !ethers.BigNumber.from(address).isZero() ? address : undefined;
}

export function prepareUpgradeHarnessInputs(
  scenario: PipelineUpgradeScenario,
  hop: RecurringUpgradeHop,
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
  /** The template's `rollup_da_manager` when it names one; otherwise protocol-ops resolves the CTM's own. */
  rollupDaManagerAddress?: string;
  create2FactorySalt: string;
  ctmProxyAddress: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", `upgrade-harness-inputs-${hop.label}`);
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, `${hop.label}-permanent-values.toml`);
  const upgradeInputPath = path.join(tempDir, `${hop.label}-upgrade-input.toml`);
  const ecosystemOutputPath = path.join(tempDir, `${hop.label}-upgrade-ecosystem.toml`);
  const protocolOpsOutDir = path.join(tempDir, "protocol-ops");

  const primaryChainId = state.chainAddresses[0]?.chainId;
  if (!primaryChainId) throw new Error(`No chains loaded for ${hop.label}`);

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
    ethers.utils.id(`anvil-interop upgrade ${hop.label}`)
  );
  fs.writeFileSync(permanentValuesPath, permanentValues);

  let upgradeInput = fs.readFileSync(path.join(l1ContractsDir, hop.upgradeInputTemplatePath), "utf8");
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
    rollupDaManagerAddress: nonZeroAddress(permanentValuesToml.ctm_contracts?.rollup_da_manager),
    create2FactorySalt: permanentValuesToml.permanent_contracts?.create2_factory_salt ?? ethers.constants.HashZero,
    ctmProxyAddress: state.ctmAddresses.chainTypeManager,
    // Kept alongside the chains: debugging a run needs the INPUTS that produced it (the
    // merged prepare TOML is also what `protocol-ops ecosystem verify-package` consumes),
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
