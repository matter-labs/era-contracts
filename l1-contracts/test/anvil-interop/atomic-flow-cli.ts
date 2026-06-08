/**
 * Interactive atomic-flow demo CLI.
 *
 * Drives a two-leg cross-chain swap end to end and persists everything to a JSON file
 * (`atomic-flow-state.json` by default, override with `--state <path>`). A swap is a pair of legs
 * `(srcChainId, payer, token)` -> `(dstChainId, recipient)`; the CLI auto-resolves leg ids
 * (`specHash`) and the `flowId`, then lets each signer do their part.
 *
 * The state file also holds a `config` section that must be filled with deployed addresses:
 *   {
 *     "config": {
 *       "l1":     { "rpc": "...", "registry": "0x<GlobalInteropIMT>" },
 *       "chains": { "<chainId>": { "rpc": "...", "escrow": "0x", "tree": "0x", "importer": "0x" } }
 *     },
 *     "flows": { ... }
 *   }
 *
 * Commands:
 *   register-flow-id [--default] [--legs-file <path>] [--deadline <unix>]
 *       Define the swap legs and persist the flow. With no flag the legs are entered
 *       interactively; `--default` uses the built-in sample legs; `--legs-file <path>` reads an
 *       array of SendSpec objects from a JSON file (non-interactive, for scripted demos).
 *   list-flows
 *   flow-info <flowId>
 *   commit-send <flowId> <legId> <privateKey> <rpcUrl>
 *   check-status <flowId>
 *       For each leg, reports whether its commit value is present in its origin chain's IMT.
 *   authorize <flowId> <privateKey> <rpcUrl>
 *       Authorizes the flow on the chain behind <rpcUrl>: builds IMT inclusion proofs for the
 *       remote-origin legs (local-origin legs are checked via local state) and marks the relevant
 *       specs Executable. This is the novel cross-chain step; it does not move tokens.
 *   execute <flowId> <legId> <privateKey> <rpcUrl>
 *       Executes a single (already-Executable) leg on the chain behind <rpcUrl> (AR/NTV settlement).
 *   finalize <flowId> <legId> <privateKey> <rpcUrl>
 *       Convenience: authorize the flow and then execute the given leg.
 *
 * All commands take an optional `--state <path>`.
 */

import * as fs from "fs";
import * as readline from "readline";
import { BigNumber, Contract, providers, Wallet } from "ethers";
import { getAbi } from "./src/core/contracts";
import type { SendSpec } from "./src/helpers/imt-engine-lib";
import {
  buildInclusionProof,
  commitValue,
  commitmentTree,
  computeFlowId,
  globalRegistry,
  lowNullifierIndexFor,
  reconstructChainImt,
  specHashOf,
} from "./src/helpers/imt-engine-lib";

interface ChainConfig {
  rpc: string;
  escrow: string;
  tree: string;
  importer: string;
}
interface Config {
  l1: { rpc: string; registry: string };
  chains: Record<string, ChainConfig>;
}
interface Leg {
  legId: string; // specHash
  spec: SendSpec;
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
const DEFAULT_LEGS: SendSpec[] = [
  {
    originChainId: 271,
    depositor: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    originToken: "0x0000000000000000000000000000000000000000",
    amount: "100",
    destChainId: 272,
    recipient: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    erc20Data: "0x",
  },
  {
    originChainId: 272,
    depositor: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    originToken: "0x0000000000000000000000000000000000000000",
    amount: "50",
    destChainId: 271,
    recipient: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    erc20Data: "0x",
  },
];

function emptyState(): State {
  return { config: { l1: { rpc: "", registry: "" }, chains: {} }, flows: {} };
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

/** Sort legs by specHash ascending and compute the flowId (must match AtomicFlowEscrow). */
function buildFlow(specs: SendSpec[], deadline: number): Flow {
  const withHash = specs.map((s) => ({ spec: s, hash: specHashOf(s) }));
  withHash.sort((a, b) => (BigNumber.from(a.hash).lt(BigNumber.from(b.hash)) ? -1 : 1));
  const chainIds = Array.from(new Set(specs.flatMap((s) => [Number(s.originChainId), Number(s.destChainId)]))).sort(
    (a, b) => a - b
  );
  const legs: Leg[] = withHash.map((w) => ({ legId: w.hash, spec: w.spec }));
  return { deadline, chainIds, legs };
}

function flowIdOf(flow: Flow): string {
  return computeFlowId(
    flow.legs.map((l) => l.legId),
    flow.chainIds,
    flow.deadline
  );
}

async function promptLeg(label: string, dflt: SendSpec): Promise<SendSpec> {
  // eslint-disable-next-line no-console
  console.log(`\n${label} (origin -> destination):`);
  const originChainId = await ask("  origin chainId", String(dflt.originChainId));
  const depositor = await ask("  depositor (payer)", dflt.depositor);
  const originToken = await ask("  origin token", dflt.originToken);
  const amount = await ask("  amount", String(dflt.amount));
  const destChainId = await ask("  dest chainId", String(dflt.destChainId));
  const recipient = await ask("  recipient", dflt.recipient);
  return { originChainId, depositor, originToken, amount, destChainId, recipient, erc20Data: dflt.erc20Data };
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

function escrowContract(addr: string, signerOrProvider: Wallet | providers.Provider): Contract {
  return new Contract(addr, getAbi("AtomicFlowEscrow"), signerOrProvider);
}

// ── commands ────────────────────────────────────────────────────────────────────────────────

async function cmdRegister(state: State, statePath: string, flags: Record<string, string>): Promise<void> {
  const deadline = flags["deadline"] ? Number(flags["deadline"]) : Math.floor(Date.now() / 1000) + 3600;
  let specs: SendSpec[];
  if (flags["legs-file"]) {
    // Non-interactive registration: read an array of SendSpec from a JSON file. Useful for
    // scripted demos where the interactive prompts cannot be driven from stdin.
    specs = JSON.parse(fs.readFileSync(flags["legs-file"], "utf8")) as SendSpec[];
  } else if (flags["default"]) {
    specs = DEFAULT_LEGS;
  } else {
    specs = [
      await promptLeg("First part of the swap", DEFAULT_LEGS[0]),
      await promptLeg("Second part of the swap", DEFAULT_LEGS[1]),
    ];
  }
  const flow = buildFlow(specs, deadline);
  const flowId = flowIdOf(flow);
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

async function cmdCommit(state: State, flowId: string, legId: string, pk: string, rpc: string): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const leg = flow.legs.find((l) => l.legId === legId);
  if (!leg) throw new Error(`unknown legId ${legId}`);

  const provider = new providers.JsonRpcProvider(rpc);
  const wallet = new Wallet(pk, provider);
  const chainCfg = requireChain(state, Number(leg.spec.originChainId));

  const value = commitValue(flowId, leg.legId);
  const lowNull = await lowNullifierIndexFor(commitmentTree(chainCfg.tree, provider), value);

  const escrow = escrowContract(chainCfg.escrow, wallet);
  const tx = await escrow.commitSend(flowId, specTuple(leg.spec), lowNull);
  await tx.wait();
  // eslint-disable-next-line no-console
  console.log(`committed leg ${legId} on chain ${leg.spec.originChainId} (tx ${tx.hash})`);
}

async function cmdCheckStatus(state: State, flowId: string): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const statuses = [];
  for (const leg of flow.legs) {
    const chainCfg = requireChain(state, Number(leg.spec.originChainId));
    const provider = new providers.JsonRpcProvider(chainCfg.rpc);
    const value = commitValue(flowId, leg.legId);
    const imt = await reconstructChainImt(commitmentTree(chainCfg.tree, provider));
    const committed = imt.leaves.some((l) => BigNumber.from(l.value).eq(BigNumber.from(value)));
    statuses.push({ legId: leg.legId, originChainId: Number(leg.spec.originChainId), committed });
  }
  const allCommitted = statuses.every((s) => s.committed);
  print({ flowId, allCommitted, legs: statuses });
}

/**
 * Send `authorize` for the whole flow on the chain behind `rpc`: builds inclusion proofs for every
 * leg that did NOT originate on that chain (local-origin legs are verified via local state) and
 * submits them. Returns the finalizing chainId. Shared by the `authorize` and `finalize` commands.
 */
async function authorizeFlow(state: State, flowId: string, pk: string, rpc: string): Promise<number> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);

  const provider = new providers.JsonRpcProvider(rpc);
  const wallet = new Wallet(pk, provider);
  // The finalizing chain is the one behind `rpc`; use its escrow + importer.
  const chainId = (await provider.getNetwork()).chainId;
  const chainCfg = requireChain(state, chainId);
  const importer = new Contract(chainCfg.importer, getAbi("L2GlobalInteropRootImporter"), provider);

  // Pick the latest imported global root whose timestamp is <= deadline.
  const l1Block = await pickImportedBlock(importer, flow.deadline);
  const l1Provider = new providers.JsonRpcProvider(state.config.l1.rpc);
  const registry = globalRegistry(state.config.l1.registry, l1Provider);

  // `authorize` only needs proofs for specs that did NOT originate on the finalizing chain — specs
  // committed here are verified via local state. Build proofs for the remote-origin legs, in the
  // flow's sorted leg order.
  const proofs = [];
  for (const l of flow.legs) {
    if (Number(l.spec.originChainId) === chainId) continue;
    const originCfg = requireChain(state, Number(l.spec.originChainId));
    const originProvider = new providers.JsonRpcProvider(originCfg.rpc);
    const value = commitValue(flowId, l.legId);
    proofs.push(
      await buildInclusionProof({
        l2Tree: commitmentTree(originCfg.tree, originProvider),
        registry,
        chainId: l.spec.originChainId,
        value,
        l1Block,
      })
    );
  }

  const escrow = escrowContract(chainCfg.escrow, wallet);
  const specs = flow.legs.map((l) => specTuple(l.spec));
  const authTx = await escrow.authorize(flowId, specs, flow.chainIds, flow.deadline, proofs.map(proofTuple));
  await authTx.wait();
  // eslint-disable-next-line no-console
  console.log(`authorized flow ${flowId} on chain ${chainId} (${proofs.length} inclusion proof(s), tx ${authTx.hash})`);
  return chainId;
}

/** `authorize` command: authorize the flow on the chain behind `rpc` (no execute). */
async function cmdAuthorize(state: State, flowId: string, pk: string, rpc: string): Promise<void> {
  await authorizeFlow(state, flowId, pk, rpc);
}

/** `execute` command: execute a single leg on the chain behind `rpc` (must already be Executable). */
async function cmdExecute(state: State, flowId: string, legId: string, pk: string, rpc: string): Promise<void> {
  const flow = state.flows[flowId];
  if (!flow) throw new Error(`unknown flowId ${flowId}`);
  const leg = flow.legs.find((l) => l.legId === legId);
  if (!leg) throw new Error(`unknown legId ${legId}`);

  const provider = new providers.JsonRpcProvider(rpc);
  const wallet = new Wallet(pk, provider);
  const chainId = (await provider.getNetwork()).chainId;
  const chainCfg = requireChain(state, chainId);
  const escrow = escrowContract(chainCfg.escrow, wallet);
  const execTx = await escrow.execute(flowId, specTuple(leg.spec));
  await execTx.wait();
  // eslint-disable-next-line no-console
  console.log(`executed leg ${legId} on chain ${chainId} (tx ${execTx.hash})`);
}

async function cmdFinalize(state: State, flowId: string, legId: string, pk: string, rpc: string): Promise<void> {
  await authorizeFlow(state, flowId, pk, rpc);
  await cmdExecute(state, flowId, legId, pk, rpc);
}

/** Latest imported L1 block on `importer` whose timestamp is <= deadline. */
async function pickImportedBlock(importer: Contract, deadline: number): Promise<number> {
  const count = (await importer.importedCount()).toNumber();
  let best = -1;
  for (let i = 0; i < count; i++) {
    const block = (await importer.importedBlockAt(i)).toNumber();
    const ts = (await importer.timestampAt(block)).toNumber();
    if (ts <= deadline && block > best) best = block;
  }
  if (best < 0) throw new Error(`no imported global root with timestamp <= deadline ${deadline}`);
  return best;
}

function specTuple(s: SendSpec): unknown[] {
  return [s.destChainId, s.recipient, s.originChainId, s.originToken, s.amount, s.erc20Data, s.depositor];
}

function proofTuple(p: Awaited<ReturnType<typeof buildInclusionProof>>): unknown[] {
  return [
    p.chainId,
    p.chainImtRoot,
    [p.leaf.value, p.leaf.nextValue, p.leaf.nextIndex],
    p.imtLeafIndex,
    p.imtProof,
    p.globalLeafIndex,
    p.globalProof,
    p.l1BlockNumber,
  ];
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
    case "commit-send":
      await cmdCommit(state, positionals[0], positionals[1], positionals[2], positionals[3]);
      break;
    case "check-status":
      await cmdCheckStatus(state, positionals[0]);
      break;
    case "authorize":
      await cmdAuthorize(state, positionals[0], positionals[1], positionals[2]);
      break;
    case "execute":
      await cmdExecute(state, positionals[0], positionals[1], positionals[2], positionals[3]);
      break;
    case "finalize":
      await cmdFinalize(state, positionals[0], positionals[1], positionals[2], positionals[3]);
      break;
    default:
      throw new Error(
        `unknown command "${command ?? ""}". Use: register-flow-id | list-flows | flow-info | commit-send | check-status | authorize | execute | finalize`
      );
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
