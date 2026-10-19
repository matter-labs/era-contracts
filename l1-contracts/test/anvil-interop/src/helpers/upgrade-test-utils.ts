/**
 * Small utilities shared by the upgrade test runners: version and chain selection, proxy slot
 * reads, failed-transaction traces, the chain-side view of the direct upgrade legs (executor
 * discovery, leg encoding, and the assertions that one governance execution applied them), and the
 * post-state an applied CTM transition leaves.
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { EIP1967_ADMIN_SLOT, EIP1967_IMPL_SLOT, SEMVER_MAJOR_OFFSET, SEMVER_MINOR_OFFSET } from "../core/const";
import { getAbi } from "../core/contracts";
import type { ChainRole } from "../core/types";
import type { ExpectedCall, UpgradeLeg, UpgradeLegKind, UpgradeLegSelectors } from "./governance-bundle";
import { UPGRADE_LEG_KINDS } from "./governance-bundle";
import type { ProxyUpgradeDomainName } from "./registry-manifest";
import { proxyUpgradeDomain } from "./registry-manifest";

// The genesis config the default upgrade scripts read their target version from.
const ZKSYNC_OS_GENESIS_PATH = path.resolve(__dirname, "../../../../../configs/genesis/zksync-os/latest.json");

export type SemVer = { major: number; minor: number; patch: number };

/**
 * The protocol version in the ZKsync OS genesis config: the version `DefaultCoreUpgrade` / `DefaultCTMUpgrade`
 * upgrade to, so the target of protocol-ops' default upgrade.
 */
export function readGenesisSemVer(): SemVer {
  const genesis = JSON.parse(fs.readFileSync(ZKSYNC_OS_GENESIS_PATH, "utf-8")) as {
    protocol_semantic_version: SemVer;
  };
  return genesis.protocol_semantic_version;
}

/** `version` packed like `SemVer.packSemVer`, as a hex string. */
export function packProtocolVersion(version: SemVer): string {
  return ethers.BigNumber.from(version.major)
    .shl(SEMVER_MAJOR_OFFSET)
    .or(ethers.BigNumber.from(version.minor).shl(SEMVER_MINOR_OFFSET))
    .or(version.patch)
    .toHexString();
}

/**
 * Test-only compatibility bridge: the pre-generated chain states still carry the genesis-upgrade
 * tx hash from chain creation, which a real chain's server clears once it processes the batch and
 * which otherwise blocks a new upgrade with `PreviousUpgradeNotFinalized`.
 */
export async function clearGenesisUpgradeTxHash(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  for (const chain of chains) {
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, "0x22", ethers.constants.HashZero]);
  }
}

/** A transparent proxy's admin, read from its EIP-1967 slot: the proxy answers `admin()` only to it. */
export async function readProxyAdmin(provider: ethers.providers.Provider, proxy: string): Promise<string> {
  return readAddressSlot(provider, proxy, EIP1967_ADMIN_SLOT);
}

/** A transparent proxy's implementation, read from its EIP-1967 slot. */
export async function readProxyImplementation(provider: ethers.providers.Provider, proxy: string): Promise<string> {
  return readAddressSlot(provider, proxy, EIP1967_IMPL_SLOT);
}

async function readAddressSlot(provider: ethers.providers.Provider, account: string, slot: string): Promise<string> {
  return ethers.utils.getAddress(ethers.utils.hexDataSlice(await provider.getStorageAt(account, slot), 12));
}

export function selectUpgradeChains(
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>,
  chainConfigs: Array<{ chainId: number; role: ChainRole }>,
  targetRoles: ChainRole[]
): Array<{ chainId: number; diamondProxy: string }> {
  const roles = new Map(chainConfigs.map((c) => [c.chainId, c.role]));
  return chainAddresses.filter((chain) => {
    const role = roles.get(chain.chainId);
    if (!role) throw new Error(`Missing chain role for chain ${chain.chainId}`);
    return targetRoles.includes(role);
  });
}

/**
 * The chains among `chains` that settle on L1 in the loaded states. Roles come from the current config, whose
 * topology can differ from that of an older release's states, so the settlement layer is read on-chain.
 */
export async function keepL1SettledChains(
  l1Provider: ethers.providers.JsonRpcProvider,
  bridgehubAddr: string,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<Array<{ chainId: number; diamondProxy: string }>> {
  const bridgehub = new ethers.Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Provider);
  const l1ChainId = (await l1Provider.getNetwork()).chainId;
  const settledOnL1: Array<{ chainId: number; diamondProxy: string }> = [];
  for (const chain of chains) {
    if ((await bridgehub.settlementLayer(chain.chainId)).eq(l1ChainId)) {
      settledOnL1.push(chain);
    }
  }
  return settledOnL1;
}

/**
 * Trace a failed transaction via receipt + eth_call replay and return a human-readable summary.
 */
export async function traceFailedTx(provider: ethers.providers.JsonRpcProvider, txHash: string): Promise<string> {
  try {
    const tx = await provider.getTransaction(txHash);
    const receipt = await provider.getTransactionReceipt(txHash);
    const selector = tx.data?.slice(0, 10) ?? "unknown";
    const lines = [
      `  tx: ${txHash}`,
      `  from: ${tx.from}`,
      `  to: ${tx.to}`,
      `  selector: ${selector}`,
      `  gasUsed: ${receipt?.gasUsed?.toString() ?? "?"}`,
      `  block: ${receipt?.blockNumber ?? "?"}`,
    ];

    // Try to get revert reason via eth_call replay
    try {
      await provider.call(
        { from: tx.from, to: tx.to!, data: tx.data, value: tx.value, gasLimit: tx.gasLimit },
        receipt?.blockNumber ? receipt.blockNumber - 1 : "latest"
      );
    } catch (callErr: unknown) {
      const reason =
        callErr instanceof Error
          ? ((callErr as { reason?: string }).reason ?? callErr.message.slice(0, 200))
          : String(callErr).slice(0, 200);
      lines.push(`  revert reason: ${reason}`);
    }

    lines.push(`  Debug: cast run ${txHash} --rpc-url ${provider.connection.url}`);
    return lines.join("\n");
  } catch {
    return `  tx: ${txHash}\n  (could not fetch trace details)`;
  }
}

// ── Direct upgrade legs ──────────────────────────────────────────────

/** The two domain executors of an ecosystem. */
export type DomainExecutors = { coreExecutor: string; ctmExecutor: string };

async function requireCode(provider: ethers.providers.Provider, account: string, what: string): Promise<void> {
  if ((await provider.getCode(account)) === "0x") {
    throw new Error(`${what} ${account} has no code`);
  }
}

/**
 * The domain executors, each found through the custody it holds — neither names the other: the CTM
 * executor is the CTM's owner and must be bound to that CTM (`CHAIN_TYPE_MANAGER()`); the core
 * executor is the ecosystem ProxyAdmin's owner and must be bound to that admin (`PROXY_ADMIN()`).
 * Throws when either binding fails.
 * @param ecosystemProxyAdmin The ecosystem ProxyAdmin (e.g. the MessageRoot proxy's admin).
 */
export async function discoverDomainExecutors(
  provider: ethers.providers.Provider,
  ctmAddr: string,
  ecosystemProxyAdmin: string
): Promise<DomainExecutors> {
  const ctmExecutor = ethers.utils.getAddress(
    await new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), provider).owner()
  );
  await requireCode(provider, ctmExecutor, `the owner of CTM ${ctmAddr},`);
  const boundCtm: string = await new ethers.Contract(
    ctmExecutor,
    getAbi("CTMUpgradeExecutor"),
    provider
  ).CHAIN_TYPE_MANAGER();
  if (boundCtm.toLowerCase() !== ctmAddr.toLowerCase()) {
    throw new Error(`CTM executor ${ctmExecutor} owns CTM ${ctmAddr} but is bound to ${boundCtm}`);
  }

  const coreExecutor = ethers.utils.getAddress(
    await new ethers.Contract(ecosystemProxyAdmin, getAbi("ProxyAdmin"), provider).owner()
  );
  await requireCode(provider, coreExecutor, `the owner of the ecosystem ProxyAdmin ${ecosystemProxyAdmin},`);
  const boundAdmin: string = await new ethers.Contract(
    coreExecutor,
    getAbi("CoreUpgradeExecutor"),
    provider
  ).PROXY_ADMIN();
  if (boundAdmin.toLowerCase() !== ecosystemProxyAdmin.toLowerCase()) {
    throw new Error(
      `core executor ${coreExecutor} owns the ecosystem ProxyAdmin ${ecosystemProxyAdmin} but is bound to ${boundAdmin}`
    );
  }
  return { coreExecutor, ctmExecutor };
}

// ── Post-state of an applied upgrade ─────────────────────────────────

/**
 * `  what: live L, expected E` when `live` differs from `expected`, as a one-element list to spread
 * into a mismatch report; none when they agree. Strings compare case-insensitively, `BigNumber`s
 * print as hex.
 */
export function mismatch(what: string, live: unknown, expected: unknown): string[] {
  const show = (v: unknown) => (ethers.BigNumber.isBigNumber(v) ? v.toHexString() : String(v));
  return show(live).toLowerCase() === show(expected).toLowerCase()
    ? []
    : [`  ${what}: live ${show(live)}, expected ${show(expected)}`];
}

/**
 * Throws, naming every mismatch, unless `ctmExecutor` holds the CTM domain: it is bound to the CTM
 * and to the CTM's ProxyAdmin and owns both, with no nomination outstanding on the CTM; the CTM's
 * ServerNotifier sits under that ProxyAdmin, is owned by `ctmExecutor` with no nomination
 * outstanding, and is bound to the CTM both ways (`serverNotifierAddress()`, `chainTypeManager()`).
 * Returns the ProxyAdmin and the ServerNotifier it read.
 */
export async function assertCtmDomainHeldBy(
  provider: ethers.providers.Provider,
  ctmAddr: string,
  ctmExecutor: string
): Promise<{ ctmProxyAdmin: string; serverNotifier: string }> {
  await requireCode(provider, ctmExecutor, "the CTM executor");
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), provider);
  const ctmOwnable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), provider);
  const executor = new ethers.Contract(ctmExecutor, getAbi("CTMUpgradeExecutor"), provider);
  const ctmProxyAdmin = await readProxyAdmin(provider, ctmAddr);
  const serverNotifier = ethers.utils.getAddress(await ctm.serverNotifierAddress());
  await requireCode(provider, serverNotifier, `the ServerNotifier CTM ${ctmAddr} names,`);
  const notifier = new ethers.Contract(serverNotifier, getAbi("ServerNotifier"), provider);
  const zero = ethers.constants.AddressZero;
  const problems = [
    ...mismatch("CTM owner()", await ctmOwnable.owner(), ctmExecutor),
    ...mismatch("CTM pendingOwner()", await ctmOwnable.pendingOwner(), zero),
    ...mismatch(
      `CTM ProxyAdmin ${ctmProxyAdmin} owner()`,
      await new ethers.Contract(ctmProxyAdmin, getAbi("ProxyAdmin"), provider).owner(),
      ctmExecutor
    ),
    ...mismatch("CTM executor CHAIN_TYPE_MANAGER()", await executor.CHAIN_TYPE_MANAGER(), ctmAddr),
    ...mismatch("CTM executor CTM_PROXY_ADMIN()", await executor.CTM_PROXY_ADMIN(), ctmProxyAdmin),
    ...mismatch(`ServerNotifier ${serverNotifier} owner()`, await notifier.owner(), ctmExecutor),
    ...mismatch(`ServerNotifier ${serverNotifier} pendingOwner()`, await notifier.pendingOwner(), zero),
    ...mismatch(`ServerNotifier ${serverNotifier} chainTypeManager()`, await notifier.chainTypeManager(), ctmAddr),
    ...mismatch(
      `ServerNotifier ${serverNotifier} proxy admin`,
      await readProxyAdmin(provider, serverNotifier),
      ctmProxyAdmin
    ),
  ];
  if (problems.length !== 0) {
    throw new Error(`CTM executor ${ctmExecutor} does not hold the domain of CTM ${ctmAddr}:\n${problems.join("\n")}`);
  }
  return { ctmProxyAdmin, serverNotifier };
}

/**
 * Throws, naming every mismatch, unless `transition` is applied on the CTM: it departs from
 * `oldVersion` and is committed for it, the CTM runs its new version on its target release, that
 * release's own `protocolVersion()` agrees, and `ctmExecutor` still holds the CTM domain
 * ({@link assertCtmDomainHeldBy}).
 */
export async function assertCtmTransitionApplied(
  provider: ethers.providers.Provider,
  ctmAddr: string,
  transitionAddr: string,
  oldVersion: ethers.BigNumber,
  ctmExecutor: string
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), provider);
  const transition = new ethers.Contract(transitionAddr, getAbi("ICTMTransition"), provider);
  const version: ethers.BigNumber = await ctm.protocolVersion();
  const currentRelease: string = await ctm.currentRelease();
  const problems = [
    ...mismatch("transition oldProtocolVersion()", await transition.oldProtocolVersion(), oldVersion),
    ...mismatch(
      `CTM upgradeTransition(${oldVersion.toHexString()})`,
      await ctm.upgradeTransition(oldVersion),
      transitionAddr
    ),
    ...mismatch("CTM protocolVersion()", version, await transition.newProtocolVersion()),
    ...mismatch("CTM currentRelease()", currentRelease, await transition.newRelease()),
  ];
  if ((await provider.getCode(currentRelease)) === "0x") {
    problems.push(`  CTM currentRelease() ${currentRelease} has no code`);
  } else {
    const release = new ethers.Contract(currentRelease, getAbi("ICTMRelease"), provider);
    problems.push(...mismatch(`release ${currentRelease} protocolVersion()`, await release.protocolVersion(), version));
  }
  if (problems.length !== 0) {
    throw new Error(`CTMTransition ${transitionAddr} is not applied on CTM ${ctmAddr}:\n${problems.join("\n")}`);
  }
  await assertCtmDomainHeldBy(provider, ctmAddr, ctmExecutor);
}

/** Each leg's executor contract, entrypoint and domain event. */
const LEG_ENTRYPOINTS: Record<
  UpgradeLegKind,
  { executor: "CoreUpgradeExecutor" | "CTMUpgradeExecutor"; method: string; event: string }
> = {
  core: { executor: "CoreUpgradeExecutor", method: "applyL1Upgrade", event: "L1UpgradeApplied" },
  ctmInfrastructure: {
    executor: "CTMUpgradeExecutor",
    method: "applyInfrastructureUpgrade",
    event: "CTMInfrastructureUpgradeApplied",
  },
  ctmTransition: { executor: "CTMUpgradeExecutor", method: "applyCTMUpgrade", event: "CTMUpgradeApplied" },
};

/** The domain of the `ProxyUpgradeTransition` a row-object leg applies; the transition leg has none. */
const LEG_PROXY_UPGRADE_DOMAIN: Partial<Record<UpgradeLegKind, ProxyUpgradeDomainName>> = {
  core: "Core",
  ctmInfrastructure: "CTM",
};

function legInterface(kind: UpgradeLegKind): ethers.utils.Interface {
  return new ethers.utils.Interface(getAbi(LEG_ENTRYPOINTS[kind].executor));
}

/** The leg entrypoint selectors, from the executor ABIs. */
export function upgradeLegSelectors(): UpgradeLegSelectors {
  return Object.fromEntries(
    UPGRADE_LEG_KINDS.map((kind) => [kind, legInterface(kind).getSighash(LEG_ENTRYPOINTS[kind].method)])
  ) as UpgradeLegSelectors;
}

/** `leg` as the governance call that applies it. */
export function upgradeLegCall(leg: UpgradeLeg): ExpectedCall {
  const { executor, method } = LEG_ENTRYPOINTS[leg.kind];
  return {
    label: `${executor}.${method}(${leg.object})`,
    target: leg.executor,
    data: legInterface(leg.kind).encodeFunctionData(method, [leg.object]),
  };
}

/** A row-object leg's rows, with the implementation each proxy ran before the legs were applied. */
export type ProxyUpgradeLegSnapshot = {
  leg: UpgradeLeg;
  rows: Array<{ proxy: string; implNew: string; implBefore: string }>;
};

/**
 * Reads each row-object leg's `ProxyUpgradeTransition` before execution: it must be of the leg's
 * domain, and every row's live implementation is recorded so the execution's swaps can be told from
 * its idempotent skips. The transition leg carries no rows and is skipped.
 */
export async function snapshotProxyUpgradeLegs(
  provider: ethers.providers.Provider,
  legs: UpgradeLeg[]
): Promise<ProxyUpgradeLegSnapshot[]> {
  const snapshots: ProxyUpgradeLegSnapshot[] = [];
  for (const leg of legs) {
    const domain = LEG_PROXY_UPGRADE_DOMAIN[leg.kind];
    if (!domain) {
      continue;
    }
    const object = new ethers.Contract(leg.object, getAbi("IProxyUpgradeTransition"), provider);
    const liveDomain: number = await object.domain();
    if (liveDomain !== proxyUpgradeDomain(domain)) {
      throw new Error(`the ${leg.kind} leg's object ${leg.object} is of domain ${liveDomain}, expected ${domain}`);
    }
    const rows: Array<{ proxy: string; implNew: string }> = await object.rows();
    snapshots.push({
      leg,
      rows: await Promise.all(
        rows.map(async (row) => ({
          proxy: row.proxy,
          implNew: row.implNew,
          implBefore: await readProxyImplementation(provider, row.proxy),
        }))
      ),
    });
  }
  return snapshots;
}

/**
 * The one transaction that applied `legs` since `fromBlock`: each executor emitted its leg's domain
 * event naming the leg's object exactly once, all in the same transaction. Throws otherwise —
 * legs applied by separate transactions would not roll back together.
 */
export async function findLegExecution(
  provider: ethers.providers.Provider,
  legs: UpgradeLeg[],
  fromBlock: number
): Promise<ethers.providers.TransactionReceipt> {
  const txHashes = new Set<string>();
  for (const leg of legs) {
    const executor = new ethers.Contract(leg.executor, legInterface(leg.kind), provider);
    const event = LEG_ENTRYPOINTS[leg.kind].event;
    const found = await executor.queryFilter(executor.filters[event](leg.object), fromBlock);
    if (found.length !== 1) {
      throw new Error(
        `${event}(${leg.object}) was emitted ${found.length} time(s) since block ${fromBlock}, expected once`
      );
    }
    txHashes.add(found[0].transactionHash);
  }
  if (txHashes.size !== 1) {
    throw new Error(
      `the legs were applied by ${txHashes.size} transactions (${[...txHashes].join(", ")}), expected one`
    );
  }
  return provider.getTransactionReceipt([...txHashes][0]);
}

/**
 * Throws unless `receipt` is one execution of `legs`: each executor's domain event names its leg's
 * object exactly once, in leg order; every row of each row-object leg now runs its `implNew`; and
 * `ProxyImplementationUpgraded` was emitted (by that leg's executor) exactly for the rows whose
 * proxy ran something else before. Returns the number of rows and of actual swaps checked.
 */
export async function assertLegsApplied(
  provider: ethers.providers.Provider,
  receipt: ethers.providers.TransactionReceipt,
  legs: UpgradeLeg[],
  snapshots: ProxyUpgradeLegSnapshot[]
): Promise<{ rows: number; swaps: number }> {
  const parsedFrom = (executor: string, iface: ethers.utils.Interface) => {
    const topics = new Set(Object.values(iface.events).map((fragment) => iface.getEventTopic(fragment)));
    return receipt.logs
      .filter((log) => log.address.toLowerCase() === executor.toLowerCase() && topics.has(log.topics[0]))
      .map((log) => ({ log, event: iface.parseLog(log) }));
  };

  let previousLogIndex = -1;
  for (const leg of legs) {
    const event = LEG_ENTRYPOINTS[leg.kind].event;
    const applied = parsedFrom(leg.executor, legInterface(leg.kind)).filter(({ event: e }) => e.name === event);
    if (applied.length !== 1 || applied[0].event.args[0].toLowerCase() !== leg.object.toLowerCase()) {
      throw new Error(
        `tx ${receipt.transactionHash}: expected exactly one ${event}(${leg.object}) from ${leg.executor}`
      );
    }
    if (applied[0].log.logIndex <= previousLogIndex) {
      throw new Error(`tx ${receipt.transactionHash}: the ${leg.kind} leg ran out of the canonical order`);
    }
    previousLogIndex = applied[0].log.logIndex;
  }

  let rows = 0;
  let swaps = 0;
  for (const { leg, rows: legRows } of snapshots) {
    const emitted = parsedFrom(leg.executor, legInterface(leg.kind))
      .filter(({ event }) => event.name === "ProxyImplementationUpgraded")
      .map(({ event }) => ({ proxy: event.args.proxy as string, newImpl: event.args.newImpl as string }));
    const expectedSwaps = legRows.filter((row) => row.implBefore.toLowerCase() !== row.implNew.toLowerCase());
    const describe = (list: Array<{ proxy: string; newImpl?: string; implNew?: string }>) =>
      JSON.stringify(list.map((r) => `${r.proxy}->${r.newImpl ?? r.implNew}`.toLowerCase()).sort());
    if (describe(emitted) !== describe(expectedSwaps)) {
      throw new Error(
        `the ${leg.kind} leg swapped ${describe(emitted)}, but its object's rows that moved are ${describe(expectedSwaps)}`
      );
    }
    for (const row of legRows) {
      const live = await readProxyImplementation(provider, row.proxy);
      if (live.toLowerCase() !== row.implNew.toLowerCase()) {
        throw new Error(`proxy ${row.proxy} runs ${live}, but the ${leg.kind} leg's row installs ${row.implNew}`);
      }
    }
    rows += legRows.length;
    swaps += expectedSwaps.length;
  }
  return { rows, swaps };
}
