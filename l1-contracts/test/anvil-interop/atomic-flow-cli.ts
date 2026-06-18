/**
 * Interactive atomic-flow demo CLI (L1-free atomic interop, bundle model).
 *
 * Drives a two-leg cross-chain swap end to end and persists everything to a JSON file
 * (`atomic-flow-state.json` by default, override with `--state <path>`). A swap is a pair of legs
 * `(srcChainId, payer, token, amount)` -> `(dstChainId, recipient)`; the CLI predicts each leg's
 * `bundleHash` (via a non-atomic `callStatic.sendBundle` on the source InteropCenter) and derives the
 * `flowId`, then lets each signer do their part.
 *
 * The flow runs through the production interop contracts:
 *   - SEND    `InteropCenter.sendBundle` with the `atomicBundle(flowId, deadline, lowNullifierIndex)`
 *             attribute (burns via the AR's `initiateIndirectCall`, appends the leg's commit value to
 *             the chain's {L2InteropCommitmentTree} via {AtomicFlowManager.append}).
 *   - RECEIVE `InteropHandler.executeAtomicBundle(bundleBytes, AtomicFinalityProof)` once every leg of
 *             the flow is proven committed before the deadline.
 *   - TIMEOUT `AtomicFlowManager.authorizeRefund` + `claimRefund`.
 *
 * The global IMT + L1 registry / importer are gone: a chain's commitment-tree root is carried by the
 * standard interop-root channel and authenticated via the `(root)` L2->L1 message; the deadline is a
 * settlement-layer block number derived in-module from the same proof.
 *
 * The state file holds a `config` section that must be filled with deployed addresses:
 *   {
 *     "config": {
 *       "chains": { "<chainId>": { "rpc": "...", "interopCenter": "0x", "interopHandler": "0x",
 *                                  "manager": "0x", "tree": "0x", "token": "0x" } }
 *     },
 *     "flows": { ... }
 *   }
 *
 * Commands:
 *   register-flow-id [--default] [--legs-file <path>] [--deadline <sl-block>]
 *   list-flows
 *   flow-info <flowId>
 *   send <flowId> <legId> <privateKey> <rpcUrl>
 *       Atomic send of one leg on its origin chain (records the emitted bundleData in the state file).
 *   check-status <flowId>
 *       For each leg, reports its origin-chain legState and whether its commit value is in the IMT.
 *   execute <flowId> <legId> <privateKey> <rpcUrl>
 *       Executes the leg on its destination chain: builds one IMT inclusion proof per leg (every leg,
 *       SL block <= deadline) and submits executeAtomicBundle.
 *   refund <flowId> <missingLegId> <committedLegId> <privateKey> <rpcUrl>
 *       Timeout path: builds a post-deadline non-inclusion proof for the missing leg, authorizes the
 *       refund on the committed leg's origin chain, then claims it.
 *
 * All commands take an optional `--state <path>`.
 */

import * as fs from "fs";
import * as readline from "readline";
import { BigNumber, Contract, providers, Wallet } from "ethers";
import { getAbi } from "./src/core/contracts";
import { encodeEvmAddress, encodeEvmChain, encodeNtvAssetId } from "./src/core/data-encoding";
import { INTEROP_SEND_BUNDLE_GAS_LIMIT, DEFAULT_TX_GAS_LIMIT, L2_ASSET_ROUTER_ADDR } from "./src/core/const";
import {
  atomicBundleAttr,
  getInteropProtocolFee,
  getTokenTransferData,
  indirectCallAttr,
  sendInteropBundle,
} from "./src/helpers/interop-helpers";
import {
  atomicFinalityProofTuple,
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  commitmentTree,
  computeFlowId,
  findValueIndex,
  lowNullifierIndexFor,
  nonInclusionProofTuple,
  reconstructChainImt,
} from "./src/helpers/imt-engine-lib";

interface ChainConfig {
  rpc: string;
  interopCenter: string;
  interopHandler: string;
  manager: string;
  tree: string;
}
interface Config {
  chains: Record<string, ChainConfig>;
}
/** A leg: bridge `amount` of `originToken` from `originChainId` to `recipient` on `destChainId`. */
interface LegSpec {
  originChainId: number;
  depositor: string;
  originToken: string;
  amount: string;
  destChainId: number;
  recipient: string;
}
interface Leg {
  /** legId == bundleHash (predicted off-chain at register time). */
  legId: string;
  spec: LegSpec;
  /** The actual ABI-encoded InteropBundle bytes captured from the real send (filled by `send`). */
  bundleData?: string;
}
interface Flow {
  deadline: number;
  chainIds: number[];
  legs: Leg[];
}
interface State {
  config: Config;
  flows: Record<string, Flow>;
}

const DEFAULT_STATE_PATH = "atomic-flow-state.json";

// Defaults for a quick two-chain swap (chain 271 <-> 272), using the standard anvil keys.
const DEFAULT_LEGS: LegSpec[] = [
  {
    originChainId: 271,
    depositor: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    originToken: "0x0000000000000000000000000000000000000000",
    amount: "100",
    destChainId: 272,
    recipient: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  },
  {
    originChainId: 272,
    depositor: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    originToken: "0x0000000000000000000000000000000000000000",
    amount: "50",
    destChainId: 271,
    recipient: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  },
];

function emptyState(): State {
  return { config: { chains: {} }, flows: {} };
}

function loadState(path: string): State {
  if (!fs.existsSync(path)) return emptyState();
  return JSON.parse(fs.readFileSync(path, "utf8")) as State;
}

function saveState(path: string, state: State): void {
  fs.writeFileSync(path, JSON.stringify(state, null, 2));
}

function parseFlags(argv: string[]): { positionals: string[]; flags: Record<string, string> } {
  const positionals: string[] = [];
  const flags: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = i + 1 < argv.length && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
      flags[key] = val;
    } else {
      positionals.push(argv[i]);
    }
  }
  return { positionals, flags };
}

function rl(): readline.Interface {
  return readline.createInterface({ input: process.stdin, output: process.stdout });
}

async function ask(prompt: string, dflt: string): Promise<string> {
  const r = rl();
  try {
    const answer: string = await new Promise((resolve) => r.question(`${prompt} [${dflt}]: `, resolve));
    return answer.trim() === "" ? dflt : answer.trim();
  } finally {
    r.close();
  }
}

function print(obj: unknown): void {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(obj, null, 2));
}

function requireChain(state: State, chainId: number): ChainConfig {
  const cfg = state.config.chains[String(chainId)];
  if (!cfg) throw new Error(`no config for chain ${chainId}; fill the "config" section of the state file`);
  return cfg;
}

function amountWei(spec: LegSpec): BigNumber {
  // Demo amounts are whole-token strings; the test tokens use 18 decimals.
  return BigNumber.from(spec.amount).mul(BigNumber.from(10).pow(18));
}

/** The single indirect-call starter that bridges a leg's tokens to its destination recipient. */
function bridgeCallStarter(spec: LegSpec) {
  const assetId = encodeNtvAssetId(spec.originChainId, spec.originToken);
  return {
    to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
    data: getTokenTransferData(assetId, amountWei(spec), spec.recipient),
    callAttributes: [indirectCallAttr()],
  };
}

/**
 * Predict a leg's bundleHash via a non-atomic `callStatic.sendBundle` (no IMT insert, no low-nullifier;
 * the bundleHash is independent of the atomic send fields). The real atomic send reuses the same sender
 * nonce, so the salt — and thus the bundleHash — matches.
 */
async function predictBundleHash(state: State, spec: LegSpec, provider: providers.Provider): Promise<string> {
  const chainCfg = requireChain(state, spec.originChainId);
  const interopCenter = new Contract(chainCfg.interopCenter, getAbi("InteropCenter"), provider);
  const fee = await getInteropProtocolFee(provider as providers.JsonRpcProvider);
  return interopCenter.callStatic.sendBundle(encodeEvmChain(spec.destChainId), [bridgeCallStarter(spec)], [], {
    gasLimit: INTEROP_SEND_BUNDLE_GAS_LIMIT,
    value: fee,
  });
}

function flowIdOf(legHashes: string[], chainIds: number[], deadline: number): string {
  const legHashesAsc = [...legHashes].sort((a, b) => (BigNumber.from(a).lt(BigNumber.from(b)) ? -1 : 1));
  const chainIdsAsc = [...chainIds].sort((a, b) => a - b);
  return computeFlowId(legHashesAsc, chainIdsAsc, deadline);
}

async function promptLeg(label: string, dflt: LegSpec): Promise<LegSpec> {
  // eslint-disable-next-line no-console
  console.log(`\n${label} (origin -> destination):`);
  const originChainId = Number(await ask("  origin chainId", String(dflt.originChainId)));
  const depositor = await ask("  depositor (payer)", dflt.depositor);
  const originToken = await ask("  origin token", dflt.originToken);
  const amount = await ask("  amount", String(dflt.amount));
  const destChainId = Number(await ask("  dest chainId", String(dflt.destChainId)));
  const recipient = await ask("  recipient", dflt.recipient);
  return { originChainId, depositor, originToken, amount, destChainId, recipient };
}

// ── commands ────────────────────────────────────────────────────────────────────────────────

async function cmdRegister(state: State, statePath: string, flags: Record<string, string>): Promise<void> {
  // The deadline is a settlement-layer block number (not a unix timestamp).
  const deadline = flags["deadline"] ? Number(flags["deadline"]) : 1_000_000;
  let specs: LegSpec[];
  if (flags["legs-file"]) {
    specs = JSON.parse(fs.readFileSync(flags["legs-file"], "utf8")) as LegSpec[];
  } else if (flags["default"]) {
    specs = DEFAULT_LEGS;
  } else {
    specs = [
      await promptLeg("First part of the swap", DEFAULT_LEGS[0]),
      await promptLeg("Second part of the swap", DEFAULT_LEGS[1]),
    ];
  }

  // Predict each leg's bundleHash off-chain, then derive flowId.
  const legs: Leg[] = [];
  for (const spec of specs) {
    const chainCfg = requireChain(state, spec.originChainId);
    const provider = new providers.JsonRpcProvider(chainCfg.rpc);
    const bundleHash = await predictBundleHash(state, spec, provider);
    legs.push({ legId: bundleHash, spec });
  }
  const chainIds = Array.from(new Set(specs.flatMap((s) => [s.originChainId, s.destChainId]))).sort((a, b) => a - b);
  const flowId = flowIdOf(
    legs.map((l) => l.legId),
    chainIds,
    deadline
  );

  const flow: Flow = { deadline, chainIds, legs };
  state.flows[flowId] = flow;
  saveState(statePath, state);
  // eslint-disable-next-line no-console
  console.log(`registered flowId ${flowId}`);
  print(flow);
}

function cmdList(state: State): void {
  print(Object.keys(state.flows));
}

function cmdInfo(state: State, flowId: string): void {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  print({ flowId, deadline: flow.deadline, chainIds: flow.chainIds, legs: flow.legs });
}

async function cmdSend(
  state: State,
  statePath: string,
  flowId: string,
  legId: string,
  pk: string,
  rpc: string
): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const leg = flow.legs.find((l) => l.legId === legId);
  if (!leg) throw new Error(`unknown legId ${legId}`);

  const provider = new providers.JsonRpcProvider(rpc);
  const chainCfg = requireChain(state, leg.spec.originChainId);

  const value = commitValue(flowId, leg.legId);
  const lowNull = await lowNullifierIndexFor(commitmentTree(chainCfg.tree, provider), value);
  const fee = await getInteropProtocolFee(provider);

  // Approve the NTV to pull the source token for the burn.
  const wallet = new Wallet(pk, provider);
  const token = new Contract(leg.spec.originToken, getAbi("TestnetERC20Token"), wallet);
  await (await token.approve(L2_ASSET_ROUTER_ADDR, amountWei(leg.spec))).wait();

  const sendResult = await sendInteropBundle({
    sourceProvider: provider,
    destinationChainId: leg.spec.destChainId,
    callStarters: [bridgeCallStarter(leg.spec)],
    bundleAttributes: [atomicBundleAttr(flowId, flow.deadline, lowNull)],
    value: fee,
  });
  if (sendResult.bundleHash.toLowerCase() !== leg.legId.toLowerCase()) {
    throw new Error(`emitted bundleHash ${sendResult.bundleHash} != predicted ${leg.legId}`);
  }
  leg.bundleData = sendResult.bundleData;
  saveState(statePath, state);
  // eslint-disable-next-line no-console
  console.log(`sent leg ${legId} on chain ${leg.spec.originChainId} (tx ${sendResult.txHash})`);
}

async function cmdCheckStatus(state: State, flowId: string): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const statuses = [];
  for (const leg of flow.legs) {
    const chainCfg = requireChain(state, leg.spec.originChainId);
    const provider = new providers.JsonRpcProvider(chainCfg.rpc);
    const value = commitValue(flowId, leg.legId);
    const imt = await reconstructChainImt(commitmentTree(chainCfg.tree, provider));
    const inImt = findValueIndex(imt.leaves, value) >= 0;
    const manager = new Contract(chainCfg.manager, getAbi("AtomicFlowManager"), provider);
    const legState: number = await manager.legState(flowId, leg.legId);
    statuses.push({ legId: leg.legId, originChainId: leg.spec.originChainId, legState, inImt });
  }
  const allCommitted = statuses.every((s) => s.inImt);
  print({ flowId, allCommitted, legs: statuses });
}

async function cmdExecute(state: State, flowId: string, legId: string, pk: string, rpc: string): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const leg = flow.legs.find((l) => l.legId === legId);
  if (!leg) throw new Error(`unknown legId ${legId}`);
  if (!leg.bundleData) throw new Error(`leg ${legId} has no bundleData; run \`send\` first`);

  const legHashesAsc = flow.legs.map((l) => l.legId).sort((a, b) => (BigNumber.from(a).lt(BigNumber.from(b)) ? -1 : 1));
  const chainIdsAsc = [...flow.chainIds].sort((a, b) => a - b);

  // One inclusion proof per leg (every leg, in ascending bundleHash order; SL block <= deadline).
  const proofsByHash: Record<string, unknown> = {};
  for (const l of flow.legs) {
    const originCfg = requireChain(state, l.spec.originChainId);
    const originProvider = new providers.JsonRpcProvider(originCfg.rpc);
    const value = commitValue(flowId, l.legId);
    proofsByHash[l.legId] = await buildInclusionProof({
      l2Tree: commitmentTree(originCfg.tree, originProvider),
      chainId: l.spec.originChainId,
      value,
      slBlock: flow.deadline,
    });
  }
  const proofsAsc = legHashesAsc.map((h) => proofsByHash[h]);

  const finality = atomicFinalityProofTuple({
    flowId,
    deadline: flow.deadline,
    legBundleHashes: legHashesAsc,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    chainIds: chainIdsAsc,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    proofs: proofsAsc as any,
  });

  const provider = new providers.JsonRpcProvider(rpc);
  const wallet = new Wallet(pk, provider);
  const chainCfg = requireChain(state, leg.spec.destChainId);
  const handler = new Contract(chainCfg.interopHandler, getAbi("InteropHandler"), wallet);
  const tx = await handler.executeAtomicBundle(leg.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  await tx.wait();
  // eslint-disable-next-line no-console
  console.log(`executed leg ${legId} on chain ${leg.spec.destChainId} (tx ${tx.hash})`);
}

async function cmdRefund(
  state: State,
  flowId: string,
  missingLegId: string,
  committedLegId: string,
  pk: string,
  rpc: string
): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const missingLeg = flow.legs.find((l) => l.legId === missingLegId);
  const committedLeg = flow.legs.find((l) => l.legId === committedLegId);
  if (!missingLeg) throw new Error(`unknown missing legId ${missingLegId}`);
  if (!committedLeg) throw new Error(`unknown committed legId ${committedLegId}`);
  if (!committedLeg.bundleData)
    throw new Error(`committed leg ${committedLegId} has no bundleData; run \`send\` first`);

  const legHashesAsc = flow.legs.map((l) => l.legId).sort((a, b) => (BigNumber.from(a).lt(BigNumber.from(b)) ? -1 : 1));
  const chainIdsAsc = [...flow.chainIds].sort((a, b) => a - b);
  const missingIdx = legHashesAsc.findIndex((h) => h === missingLegId);

  // Non-inclusion proof for the missing leg, SL block strictly past the deadline.
  const missingCfg = requireChain(state, missingLeg.spec.originChainId);
  const missingProvider = new providers.JsonRpcProvider(missingCfg.rpc);
  const missingValue = commitValue(flowId, missingLegId);
  const nonIncl = await buildNonInclusionProof({
    l2Tree: commitmentTree(missingCfg.tree, missingProvider),
    chainId: missingLeg.spec.originChainId,
    value: missingValue,
    slBlock: flow.deadline + 1,
  });

  const provider = new providers.JsonRpcProvider(rpc);
  const wallet = new Wallet(pk, provider);
  const chainCfg = requireChain(state, committedLeg.spec.originChainId);
  const manager = new Contract(chainCfg.manager, getAbi("AtomicFlowManager"), wallet);

  const authTx = await manager.authorizeRefund(
    flowId,
    legHashesAsc,
    chainIdsAsc,
    flow.deadline,
    missingIdx,
    nonInclusionProofTuple(nonIncl),
    { gasLimit: DEFAULT_TX_GAS_LIMIT }
  );
  await authTx.wait();
  const claimTx = await manager.claimRefund(flowId, committedLeg.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  await claimTx.wait();
  // eslint-disable-next-line no-console
  console.log(`refunded leg ${committedLegId} on chain ${committedLeg.spec.originChainId} (claim tx ${claimTx.hash})`);
}

async function main(): Promise<void> {
  const [, , command, ...rest] = process.argv;
  const { positionals, flags } = parseFlags(rest);
  const statePath = flags["state"] ?? DEFAULT_STATE_PATH;
  const state = loadState(statePath);

  switch (command) {
    case "register-flow-id":
      await cmdRegister(state, statePath, flags);
      break;
    case "list-flows":
      cmdList(state);
      break;
    case "flow-info":
      cmdInfo(state, positionals[0]);
      break;
    case "send":
      await cmdSend(state, statePath, positionals[0], positionals[1], positionals[2], positionals[3]);
      break;
    case "check-status":
      await cmdCheckStatus(state, positionals[0]);
      break;
    case "execute":
      await cmdExecute(state, positionals[0], positionals[1], positionals[2], positionals[3]);
      break;
    case "refund":
      await cmdRefund(state, positionals[0], positionals[1], positionals[2], positionals[3], positionals[4]);
      break;
    default:
      throw new Error(
        `unknown command "${command ?? ""}". Use: register-flow-id | list-flows | flow-info | send | check-status | execute | refund`
      );
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
