/**
 * Bootstrap stage of the registry-driven upgrade test (the "V34 -> V35" edge).
 *
 * Models the ONE-TIME entry of a pre-registry ecosystem into the registry-driven model through
 * `RegistryBootstrapMigration` (see the Bootstrap section of docs/registry-driven-upgrades.md),
 * in front of the generic registry-driven hop the runner already performs ("V35 -> V36"):
 *
 *   1. The target chains get the LEGACY cut-taking upgrade entrypoint installed
 *      (`LegacyTestAdminFacet`): the chain states are built from CURRENT sources, whose Admin
 *      facet reads its cut from the CTM — but production chains crossing the bootstrap edge run
 *      pre-v35 facets that are HANDED the cut and verify it against `upgradeCutHash`. The
 *      legacy facet reproduces that entrypoint faithfully; the bootstrap cut itself removes it
 *      again, so the harness patch cancels itself out and the post-bootstrap chain state matches
 *      the release the CTM pins.
 *   2. The one-time ServerNotifier handover to the CTM domain, a precondition `migrate()` checks
 *      (see docs/upgrade-stage-lifecycle.md): the ChainAdmin's half, then governance's accept.
 *   3. Governance (impersonated) binds the executors to the coordinator, hands the ecosystem
 *      ProxyAdmin to the core executor, and hands the CTM and its ProxyAdmin to the deployed
 *      `RegistryBootstrapMigration`, whose manifest pins: the CTM and ServerNotifier
 *      implementation swaps (REAL source-checked proxy rows), the upgrade engine, the authored
 *      L2 remainder (the delegate's deployment, the composer defining its calldata, the published
 *      factory dependencies), the version edge and the old-version deadline, the release the
 *      edge installs (the live release's pins over the L2 table of the current build — see the
 *      runner), the bound executors and coordinator, and the governance they answer to. The cut
 *      itself is COMPOSED by the migration from those inputs.
 *   4. `migrate()` runs the whole edge in one transaction: impl swaps, legacy
 *      `setNewVersionUpgrade` commit (writing the deprecated `upgradeCutHash` — the ONLY writer
 *      left), release install, and the authority handover to the executors.
 *   5. Each chain's admin crosses the edge through the legacy 3-arg `upgradeChainFromVersion`,
 *      handing the committed cut — verified against `upgradeCutHash` exactly like production
 *      pre-v35 chains do.
 *   6. Stage 2 lifts the migration pause; the edge's completion check (`validateApplied()`) runs
 *      as its own call after it.
 *
 * After this stage the WHOLE CTM domain — the CTM, its own ProxyAdmin and the ServerNotifier — is
 * held by `CTMUpgradeExecutor`, and every later upgrade is registry-driven — which is exactly
 * what the runner's next stage exercises. (Ecosystem singletons stay under the separate ecosystem
 * ProxyAdmin / `CoreUpgradeExecutor`.)
 */

import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { impersonateAndRun } from "../core/utils";
import { proxyUpgradeSlots } from "./registry-manifest";
import type { ProxyUpgradeRowArg } from "./registry-manifest";
import { readProxyAdmin, readProxyImplementation } from "./upgrade-test-utils";

/* eslint-disable @typescript-eslint/no-explicit-any */

const DEFAULT_GAS_LIMIT = 10_000_000;

// Diamond.Action enum (contracts/state-transition/libraries/Diamond.sol).
const DIAMOND_ACTION_ADD = 0;

export type BootstrapPieces = {
  legacyAdminFacet: string;
  bootstrapEngine: string;
  ctmImplNew: string;
};

type Assert = {
  assertEq(actual: unknown, expected: unknown, message: string): void;
  assertTrue(condition: boolean, message: string): void;
};

type SendAndCheck = (
  provider: ethers.providers.JsonRpcProvider,
  txPromise: Promise<ethers.providers.TransactionResponse>,
  label: string
) => Promise<ethers.providers.TransactionReceipt>;

export function legacyUpgradeSelector(): string {
  return new ethers.utils.Interface(getAbi("LegacyTestAdminFacet")).getSighash("upgradeChainFromVersion");
}

/** The manifest's `bootstrap` section (emit mode). */
export function buildBootstrapSection(
  pieces: BootstrapPieces,
  ctmProxy: string,
  ctmImplOld: string,
  oldVersionDeadline: string
): Record<string, unknown> {
  return {
    // The pre-v35 cut-taking entrypoint the harness installs (and the bootstrap cut removes).
    legacyAdminFacet: pieces.legacyAdminFacet,
    // The bootstrap engine the composed cut's init targets — the migration's `upgradeEngine`
    // (the production `BootstrapUpgrade`, which installs the release the migration names).
    upgradeEngine: { address: pieces.bootstrapEngine },
    // The canonical bootstrap operation: the CTM proxy's own implementation swap, as a
    // source-checked row.
    ctmImpl: {
      proxy: ctmProxy,
      expectedOldImpl: ctmImplOld,
      implNew: pieces.ctmImplNew,
    },
    oldProtocolVersionDeadline: oldVersionDeadline,
  };
}

/** CONSUME-mode gate rows for the bootstrap section (same shape as the runner's other checks). */
export function bootstrapManifestChecks(
  manifest: any,
  pieces: BootstrapPieces,
  ctmProxy: string,
  ctmImplOld: string
): Array<[string, unknown, unknown]> {
  const b = manifest.bootstrap;
  return [
    ["bootstrap.legacyAdminFacet", b?.legacyAdminFacet, pieces.legacyAdminFacet],
    ["bootstrap.upgradeEngine.address", b?.upgradeEngine?.address, pieces.bootstrapEngine],
    ["bootstrap.ctmImpl.proxy", b?.ctmImpl?.proxy, ctmProxy],
    ["bootstrap.ctmImpl.expectedOldImpl", b?.ctmImpl?.expectedOldImpl, ctmImplOld],
    ["bootstrap.ctmImpl.implNew", b?.ctmImpl?.implNew, pieces.ctmImplNew],
  ];
}

/** `RegistryBootstrapMigration.BootstrapManifest` constructor argument. */
export function bootstrapInitArgs(
  manifest: any,
  packSemVer: (v: string) => bigint,
  params: {
    ctmProxy: string;
    proxyAdmin: string;
    /** The release the edge installs as the CTM's `currentRelease` (its L2 table is the derived L2 set). */
    currentRelease: string;
    ctmExecutor: string;
    coreExecutor: string;
    /** The owner every executor the edge binds must ALREADY answer to (storage, so checked by value). */
    governance: string;
    /** The coordinator (`EcosystemUpgradeExecutor`) both domain executors must answer to (also storage). */
    coordinator: string;
    upgradeTimer: string;
    /** The composer that defines the delegate calldata (the harness's fixed no-op composer). */
    delegateComposer: string;
    /** The harness's no-op delegate's bytecode info; the migration derives its address from it. */
    l2Delegate: { deployedBytecodeInfo: string };
    /** The mandatory notifier row, built from this run's fresh implementation and live state. */
    serverNotifierRow: ProxyUpgradeRowArg;
  }
): any {
  return {
    ctm: params.ctmProxy,
    expectedProtocolVersion: packSemVer(manifest.oldVersion),
    ctmProxyAdmin: params.proxyAdmin,
    // The CTM-domain inventory (indexed by `CTMContract`): this edge swaps the CTM's own
    // implementation and the ServerNotifier's, so the other slots encode as the explicit zero
    // ("not upgraded") row.
    proxyUpgrades: proxyUpgradeSlots("CTMContract", {
      ChainTypeManager: {
        proxy: manifest.bootstrap.ctmImpl.proxy,
        expectedOldImpl: manifest.bootstrap.ctmImpl.expectedOldImpl,
        implNew: manifest.bootstrap.ctmImpl.implNew,
        callInitializeUpgrade: false,
      },
      ServerNotifier: params.serverNotifierRow,
    }),
    // The release `migrate()` installs as the CTM's `currentRelease`, named by address: no hash
    // rides the manifest, since a runtime codehash cannot establish that the audited constructor
    // produced the object it is applied to. The version the edge lands on is the release's own.
    currentRelease: params.currentRelease,
    oldProtocolVersionDeadline: ethers.BigNumber.from(manifest.bootstrap.oldProtocolVersionDeadline),
    upgradeEngine: manifest.bootstrap.upgradeEngine.address,
    // The L2 leg is CONSTRUCTED on-chain from the genesis release's table plus the authored
    // delegate bytecode: its Unsafe deployment, the delegate target and the factory dependencies
    // are the migration's, and it serves the resulting cut (`upgradeCut()`) — nothing is
    // hand-built here.
    l2Plan: {
      delegateBytecodeInfo: params.l2Delegate.deployedBytecodeInfo,
      extraBytecodeInfos: [],
      delegateComposer: params.delegateComposer,
    },
    upgradeTimestamp: 0,
    // The executors and timer are deployed by this run, so their addresses come from the run
    // rather than from the committed manifest, which carries only cross-machine-stable values.
    ctmExecutor: params.ctmExecutor,
    coreExecutor: params.coreExecutor,
    governance: params.governance,
    coordinator: params.coordinator,
    upgradeTimer: params.upgradeTimer,
  };
}

/**
 * Install the legacy cut-taking entrypoint on each target chain (harness patch #1 — see module
 * docs). Runs through the CTM owner's `executeUpgrade`, the production path for owner-forced
 * cuts, BEFORE the CTM is handed to the migration.
 */
export async function installLegacyFacet(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  legacyFacet: string,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  sendAndCheck: SendAndCheck
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const ownable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const owner: string = await ownable.owner();
  const addCut = {
    facetCuts: [
      {
        facet: legacyFacet,
        action: DIAMOND_ACTION_ADD,
        isFreezable: false,
        selectors: [legacyUpgradeSelector()],
      },
    ],
    initAddress: ethers.constants.AddressZero,
    initCalldata: "0x",
  };
  await impersonateAndRun(l1Provider, owner, async (signer) => {
    for (const chain of chains) {
      await sendAndCheck(
        l1Provider,
        ctm.connect(signer).executeUpgrade(chain.chainId, addCut, { gasLimit: DEFAULT_GAS_LIMIT }),
        `install legacy facet on chain ${chain.chainId}`
      );
    }
  });
  console.log(`  ✓ legacy cut-taking entrypoint installed on ${chains.length} chain(s)`);
}

/**
 * The bindings `migrate()` requires already in place, in the order of the bootstrap's stage 1:
 * core executor -> coordinator, coordinator -> CTM executor, then the ecosystem ProxyAdmin
 * (1-step) to the core executor — each impersonating the live owner.
 */
export async function bindExecutorsForBootstrap(
  l1Provider: ethers.providers.JsonRpcProvider,
  params: { coreExecutor: string; coordinator: string; ctmExecutor: string; ecosystemProxyAdmin: string },
  sendAndCheck: SendAndCheck
): Promise<void> {
  const coreExecutor = new ethers.Contract(params.coreExecutor, getAbi("CoreUpgradeExecutor"), l1Provider);
  await impersonateAndRun(l1Provider, await coreExecutor.owner(), async (signer) => {
    await sendAndCheck(
      l1Provider,
      coreExecutor.connect(signer).setCoordinator(params.coordinator, { gasLimit: DEFAULT_GAS_LIMIT }),
      "coreExecutor.setCoordinator(coordinator)"
    );
  });
  const coordinator = new ethers.Contract(params.coordinator, getAbi("EcosystemUpgradeExecutor"), l1Provider);
  await impersonateAndRun(l1Provider, await coordinator.owner(), async (signer) => {
    await sendAndCheck(
      l1Provider,
      coordinator.connect(signer).setCTMExecutor(params.ctmExecutor, { gasLimit: DEFAULT_GAS_LIMIT }),
      "coordinator.setCTMExecutor(ctmExecutor)"
    );
  });
  const ecosystemProxyAdmin = new ethers.Contract(params.ecosystemProxyAdmin, getAbi("ProxyAdmin"), l1Provider);
  await impersonateAndRun(l1Provider, await ecosystemProxyAdmin.owner(), async (signer) => {
    await sendAndCheck(
      l1Provider,
      ecosystemProxyAdmin.connect(signer).transferOwnership(params.coreExecutor, { gasLimit: DEFAULT_GAS_LIMIT }),
      "ecosystem ProxyAdmin transferOwnership(coreExecutor)"
    );
  });
  console.log("  ✓ executors bound to the coordinator, ecosystem ProxyAdmin owned by the core executor");
}

/**
 * The edge's completion check, `RegistryBootstrapMigration.validateApplied()`, as its own call
 * after stage 2; a revert is rethrown with the decoded error.
 */
export async function assertBootstrapCompleted(
  l1Provider: ethers.providers.JsonRpcProvider,
  migrationAddr: string
): Promise<void> {
  const migration = new ethers.Contract(migrationAddr, getAbi("RegistryBootstrapMigration"), l1Provider);
  try {
    await migration.validateApplied();
  } catch (error) {
    const e = error as { errorName?: string; errorArgs?: unknown[]; message?: string };
    const reason = e.errorName ? `${e.errorName}(${(e.errorArgs ?? []).join(", ")})` : e.message;
    throw new Error(`RegistryBootstrapMigration ${migrationAddr}: validateApplied() reverted: ${reason}`);
  }
  console.log("  ✓ RegistryBootstrapMigration.validateApplied() holds");
}

/** Hand CTM (2-step nomination) + ProxyAdmin (1-step) to the migration, impersonating governance. */
export async function handAuthorityToMigration(
  l1Provider: ethers.providers.JsonRpcProvider,
  migration: string,
  ctmAddr: string,
  proxyAdminAddr: string,
  sendAndCheck: SendAndCheck
): Promise<void> {
  const ctmOwnable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const ctmOwner: string = await ctmOwnable.owner();
  await impersonateAndRun(l1Provider, ctmOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      ctmOwnable.connect(signer).transferOwnership(migration, { gasLimit: DEFAULT_GAS_LIMIT }),
      "CTM transferOwnership(migration)"
    );
  });
  const proxyAdmin = new ethers.Contract(proxyAdminAddr, getAbi("ProxyAdmin"), l1Provider);
  const proxyAdminOwner: string = await proxyAdmin.owner();
  await impersonateAndRun(l1Provider, proxyAdminOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      proxyAdmin.connect(signer).transferOwnership(migration, { gasLimit: DEFAULT_GAS_LIMIT }),
      "ProxyAdmin transferOwnership(migration)"
    );
  });
  console.log("  ✓ CTM nominated + ProxyAdmin owned by the bootstrap migration");
}

/** The CTM's ServerNotifier, read live. */
export type ServerNotifierState = {
  notifier: string;
  admin: string;
  implementation: string;
  owner: string;
  pendingOwner: string;
  chainTypeManager: string;
};

export async function readServerNotifierState(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string
): Promise<ServerNotifierState> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const notifierAddr: string = await ctm.serverNotifierAddress();
  const notifier = new ethers.Contract(notifierAddr, getAbi("ServerNotifier"), l1Provider);
  return {
    notifier: notifierAddr,
    admin: await readProxyAdmin(l1Provider, notifierAddr),
    implementation: await readProxyImplementation(l1Provider, notifierAddr),
    owner: await notifier.owner(),
    pendingOwner: await notifier.pendingOwner(),
    chainTypeManager: await notifier.chainTypeManager(),
  };
}

/** Throws unless every field `expected` names matches the live notifier; returns the live state. */
export async function assertServerNotifierState(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  expected: Partial<Omit<ServerNotifierState, "notifier">>,
  label: string
): Promise<ServerNotifierState> {
  const state = await readServerNotifierState(l1Provider, ctmAddr);
  const fields = Object.entries(expected) as Array<[keyof Omit<ServerNotifierState, "notifier">, string]>;
  const mismatches = fields
    .filter(([field, value]) => state[field].toLowerCase() !== value.toLowerCase())
    .map(([field, value]) => `  ${field}: live ${state[field]}, expected ${value}`);
  if (mismatches.length > 0) {
    throw new Error(`ServerNotifier ${state.notifier}: ${label}\n${mismatches.join("\n")}`);
  }
  console.log(`  ✓ ServerNotifier ${label} (${fields.map(([field]) => field).join(", ")})`);
  return state;
}

/**
 * The one-time ServerNotifier handover `migrate()` requires (see docs/upgrade-stage-lifecycle.md),
 * driven from live state so it completes from either notifier layout a fixture may carry and skips
 * a half already done: the ChainAdmin's half — move the proxy under `ctmProxyAdmin`, nominate the
 * executor — as the live owners, then governance's accept through the executor's `forward` (the
 * bootstrap's first stage-0 action).
 */
export async function handOverServerNotifier(
  l1Provider: ethers.providers.JsonRpcProvider,
  params: { ctmAddr: string; ctmProxyAdmin: string; ctmExecutor: string },
  sendAndCheck: SendAndCheck
): Promise<ServerNotifierState> {
  const state = await readServerNotifierState(l1Provider, params.ctmAddr);
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  if (!same(state.admin, params.ctmProxyAdmin)) {
    const oldProxyAdmin = new ethers.Contract(state.admin, getAbi("ProxyAdmin"), l1Provider);
    await callAsOwner(
      l1Provider,
      await oldProxyAdmin.owner(),
      {
        target: state.admin,
        data: oldProxyAdmin.interface.encodeFunctionData("changeProxyAdmin", [state.notifier, params.ctmProxyAdmin]),
      },
      "ServerNotifier: changeProxyAdmin(ctmProxyAdmin)",
      sendAndCheck
    );
  }
  const ownable = new ethers.utils.Interface(getAbi("Ownable2Step"));
  if (!same(state.owner, params.ctmExecutor) && !same(state.pendingOwner, params.ctmExecutor)) {
    await callAsOwner(
      l1Provider,
      state.owner,
      { target: state.notifier, data: ownable.encodeFunctionData("transferOwnership", [params.ctmExecutor]) },
      "ServerNotifier: transferOwnership(ctmExecutor)",
      sendAndCheck
    );
  }
  if (!same(state.owner, params.ctmExecutor)) {
    const executor = new ethers.Contract(params.ctmExecutor, getAbi("CTMUpgradeExecutor"), l1Provider);
    const governance: string = await executor.owner();
    const accept = { target: state.notifier, value: 0, data: ownable.encodeFunctionData("acceptOwnership", []) };
    await impersonateAndRun(l1Provider, governance, async (signer) => {
      await sendAndCheck(
        l1Provider,
        executor.connect(signer).forward([accept], { gasLimit: DEFAULT_GAS_LIMIT }),
        "ctmExecutor.forward([ServerNotifier.acceptOwnership()])"
      );
    });
  }
  return assertServerNotifierState(
    l1Provider,
    params.ctmAddr,
    {
      admin: params.ctmProxyAdmin,
      owner: params.ctmExecutor,
      pendingOwner: ethers.constants.AddressZero,
      chainTypeManager: params.ctmAddr,
    },
    "handed to the CTM domain"
  );
}

/**
 * Sends one call as `owner`, impersonated: directly from an account, otherwise through
 * `multicall` as that contract's own owner (the fixtures' ChainAdmin is a `ChainAdminOwnable`).
 */
async function callAsOwner(
  l1Provider: ethers.providers.JsonRpcProvider,
  owner: string,
  call: { target: string; data: string },
  label: string,
  sendAndCheck: SendAndCheck
): Promise<void> {
  if ((await l1Provider.getCode(owner)) === "0x") {
    await impersonateAndRun(l1Provider, owner, async (signer) => {
      await sendAndCheck(
        l1Provider,
        signer.sendTransaction({ to: call.target, data: call.data, gasLimit: DEFAULT_GAS_LIMIT }),
        label
      );
    });
    return;
  }
  const chainAdmin = new ethers.Contract(owner, getAbi("ChainAdminOwnable"), l1Provider);
  const chainAdminOwner: string = await chainAdmin.owner();
  await impersonateAndRun(l1Provider, chainAdminOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      chainAdmin
        .connect(signer)
        .multicall([{ target: call.target, value: 0, data: call.data }], true, { gasLimit: DEFAULT_GAS_LIMIT }),
      `${label} (ChainAdmin ${owner} multicall)`
    );
  });
}

/**
 * Cross the bootstrap edge on each chain through the legacy handed-cut entrypoint, as the
 * chain's own admin — the production shape for pre-v35 chains.
 */
export async function crossBootstrapEdgeOnChains(
  l1Provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  oldVersion: ethers.BigNumber,
  bootstrapCut: any,
  sendAndCheck: SendAndCheck
): Promise<void> {
  // The facet's compiled ABI (named tuple components) — a human-readable fragment cannot
  // object-encode the cut struct.
  const legacyIface = new ethers.utils.Interface(getAbi("LegacyTestAdminFacet"));
  for (const chain of chains) {
    const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
    const admin: string = await getters.getAdmin();
    const data = legacyIface.encodeFunctionData("upgradeChainFromVersion", [
      chain.diamondProxy,
      oldVersion,
      bootstrapCut,
    ]);
    await impersonateAndRun(l1Provider, admin, async (signer) => {
      await sendAndCheck(
        l1Provider,
        signer.sendTransaction({ to: chain.diamondProxy, data, gasLimit: DEFAULT_GAS_LIMIT }),
        `chain ${chain.chainId}: legacy upgradeChainFromVersion(handed cut)`
      );
    });
    console.log(`  ✓ chain ${chain.chainId} crossed the bootstrap edge (handed cut)`);
  }
}

/** Post-bootstrap assertions (L1 side). */
export async function assertBootstrapEndState(
  l1Provider: ethers.providers.JsonRpcProvider,
  a: Assert,
  params: {
    ctmAddr: string;
    migration: string;
    oldVersion: ethers.BigNumber;
    midVersion: ethers.BigNumber;
    bootstrapCut: any;
    ctmImplNew: string;
    serverNotifierImplNew: string;
    ctmExecutor: string;
    proxyAdminAddr: string;
    chains: Array<{ chainId: number; diamondProxy: string }>;
    deadline: ethers.BigNumber;
  }
): Promise<void> {
  const ctm = new ethers.Contract(params.ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const cutTypes = [
    "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)",
  ];
  const cutHash = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(cutTypes, [params.bootstrapCut]));

  a.assertEq(
    (await ctm.protocolVersion()).toString(),
    params.midVersion.toString(),
    "CTM protocol version bumped by the bootstrap edge"
  );
  // The legacy cut-taking commit is the ONE writer of the deprecated hash; no transition exists
  // for this edge, and the deadline is served from the legacy storage that same path wrote.
  a.assertEq(await ctm.upgradeCutHash(params.oldVersion), cutHash, "bootstrap edge committed the legacy cut hash");
  a.assertEq(
    await ctm.upgradeTransition(params.oldVersion),
    ethers.constants.AddressZero,
    "no transition exists for the bootstrap edge"
  );
  a.assertEq(
    (await ctm.protocolVersionDeadline(params.oldVersion)).toString(),
    params.deadline.toString(),
    "old-version deadline served from the legacy storage the bootstrap wrote"
  );

  a.assertEq(
    await readProxyImplementation(l1Provider, params.ctmAddr),
    params.ctmImplNew,
    "CTM proxy re-pointed to the fresh implementation by the bootstrap"
  );

  const migration = new ethers.Contract(params.migration, getAbi("RegistryBootstrapMigration"), l1Provider);
  a.assertTrue(await migration.executed(), "bootstrap migration marked executed");
  let replayReverted = false;
  try {
    await migration.callStatic.migrate();
  } catch {
    replayReverted = true;
  }
  a.assertTrue(replayReverted, "bootstrap migration replay reverts (one-shot edge)");

  const ctmOwnable = new ethers.Contract(params.ctmAddr, getAbi("Ownable2Step"), l1Provider);
  a.assertEq(await ctmOwnable.owner(), params.ctmExecutor, "CTM owned by CTMUpgradeExecutor after the bootstrap");
  const proxyAdmin = new ethers.Contract(params.proxyAdminAddr, getAbi("ProxyAdmin"), l1Provider);
  a.assertEq(
    await proxyAdmin.owner(),
    params.ctmExecutor,
    "CTM-domain ProxyAdmin owned by CTMUpgradeExecutor after the bootstrap"
  );
  await assertServerNotifierState(
    l1Provider,
    params.ctmAddr,
    {
      admin: params.proxyAdminAddr,
      owner: params.ctmExecutor,
      pendingOwner: ethers.constants.AddressZero,
      implementation: params.serverNotifierImplNew,
      chainTypeManager: params.ctmAddr,
    },
    "held by CTMUpgradeExecutor and re-pointed to the fresh implementation by the bootstrap"
  );

  for (const chain of params.chains) {
    const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
    a.assertEq(
      (await diamond.getProtocolVersion()).toString(),
      params.midVersion.toString(),
      `chain ${chain.chainId}: bumped to the bootstrap version`
    );
    a.assertEq(
      await diamond.facetAddress(legacyUpgradeSelector()),
      ethers.constants.AddressZero,
      `chain ${chain.chainId}: legacy cut-taking entrypoint removed by the bootstrap cut`
    );
  }
}
