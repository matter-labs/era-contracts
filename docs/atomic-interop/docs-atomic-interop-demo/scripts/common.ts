// Shared setup for the tutorial scripts: chains, accounts, contract addresses, ABIs and helpers.
import { readFileSync } from "node:fs";
import path from "node:path";
import solc from "solc";
import type { Abi, Address, BaseError, Hex, TransactionReceipt } from "viem";
import {
  ContractFunctionRevertedError,
  concat,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  getAbiItem,
  http,
  keccak256,
  parseAbi,
  parseAbiParameters,
  parseEventLogs,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ---------- Chains (local sandbox) ----------

export const L1_CHAIN_ID = 31337n;

function localChain(id: number, rpcUrl: string) {
  return defineChain({
    id,
    name: `local-${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
}

// The sandbox's ports on this machine. The demo container sets the variables to reach the chains by name.
export const l1 = localChain(31337, process.env.L1_RPC_URL ?? "http://127.0.0.1:8545");
export const chainA = localChain(506, process.env.CHAIN_A_RPC_URL ?? "http://127.0.0.1:3050");
export const chainB = localChain(507, process.env.CHAIN_B_RPC_URL ?? "http://127.0.0.1:3051");
export type Chain = typeof chainA;

// The chains make a block every 250 ms; poll at that rate instead of viem's default 4 s.
export const publicClient = (chain: Chain) => createPublicClient({ chain, transport: http(), pollingInterval: 250 });

// Test accounts with 100 ETH on both chains (Anvil's accounts #1 to #3). Never use these keys on a real network.
export const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
export const bob = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
export const executor = privateKeyToAccount("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
export type Account = typeof alice;

export const walletClient = (chain: Chain, account: Account) =>
  createWalletClient({ chain, account, transport: http(), pollingInterval: 250 });

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type SolcOutput = {
  errors?: { severity: string; formattedMessage: string }[];
  contracts: Record<string, Record<string, { abi: Abi; evm: { bytecode: { object: string } } }>>;
};

/** Compiles `contracts/<name>.sol` with solc 0.8.28, deploys the contract `name` and returns its address. */
export async function deploy(chain: Chain, account: Account, name: string, args: unknown[] = []): Promise<Address> {
  const file = `${name}.sol`;
  const input = {
    language: "Solidity",
    sources: { [file]: { content: readFileSync(path.join(__dirname, "..", "contracts", file), "utf8") } },
    settings: { outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
  };
  const output: SolcOutput = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (output.errors ?? []).filter((e) => e.severity === "error");
  if (errors.length) throw new Error(errors.map((e) => e.formattedMessage).join("\n"));
  const { abi, evm } = output.contracts[file][name];
  const hash = await walletClient(chain, account).deployContract({ abi, bytecode: `0x${evm.bytecode.object}`, args });
  const receipt = await publicClient(chain).waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) throw new Error(`deploying ${name} failed in tx ${hash}`);
  return receipt.contractAddress;
}

// ---------- System contracts (same address on every ZKsync OS chain) ----------

export const INTEROP_CENTER: Address = "0x000000000000000000000000000000000001000d";
export const INTEROP_HANDLER: Address = "0x000000000000000000000000000000000001000e";
export const INTEROP_ROOT_STORAGE: Address = "0x0000000000000000000000000000000000010008";
export const ATOMIC_FLOW_MANAGER: Address = "0x0000000000000000000000000000000000010014";
export const L2_ASSET_ROUTER: Address = "0x0000000000000000000000000000000000010003";
export const L2_NATIVE_TOKEN_VAULT: Address = "0x0000000000000000000000000000000000010004";

// ---------- ABIs (the parts of the v33 contracts the scripts use) ----------

const structs = [
  "struct FlowPreimage { bytes1 version; uint64 deadline; uint256 settlementLayerChainId; bytes32[] legBundleHashes; uint256[] legSourceChainIds; }",
  "struct Flow { bytes32 flowId; FlowPreimage preimage; }",
  "struct ImtLeaf { uint256 value; uint256 nextIndex; uint256 nextValue; }",
  "struct ImtProof { uint256 sourceChainId; uint256 batchNumber; bytes32 chainImtRoot; bool provesAgainstBeginRoot; bytes32[] settlementProof; ImtLeaf leaf; uint256 imtLeafIndex; bytes32[] imtProof; }",
  "struct FinalityProof { Flow flow; ImtProof[] proofs; }",
  "struct CallStarter { bytes to; bytes data; bytes[] callAttributes; }",
  "struct InteropCall { bytes1 version; bool shadowAccount; address to; address from; uint256 value; bytes data; }",
  "struct BundleAttributes { bytes executionAddress; bytes unbundlerAddress; bool useFixedFee; bytes32 salt; }",
  "struct InteropBundle { bytes1 version; uint256 sourceChainId; uint256 destinationChainId; bytes32 destinationBaseTokenAssetId; bytes32 interopBundleSalt; InteropCall[] calls; BundleAttributes bundleAttributes; }",
] as const;

export const abis = {
  interopCenter: parseAbi([
    ...structs,
    "function interopProtocolFee() view returns (uint256)",
    "function previewMessageHash(bytes recipient, bytes payload, bytes[] attributes)",
    "function previewBundleHash(bytes destination, CallStarter[] calls, bytes[] bundleAttributes)",
    "function sendMessage(bytes recipient, bytes payload, bytes[] attributes) payable returns (bytes32)",
    "function sendBundle(bytes destination, CallStarter[] calls, bytes[] bundleAttributes) payable returns (bytes32)",
    "event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle)",
    "error InteropPreviewHash(bytes32 bundleHash)",
  ]),
  interopHandler: parseAbi([
    ...structs,
    "function executeAtomicBundle(bytes bundle, FinalityProof finality)",
    "function bundleStatus(bytes32 bundleHash) view returns (uint8)",
    "error BundleAlreadyProcessed(bytes32 bundleHash)",
    "error ManagerProofCountMismatch(uint256 legs, uint256 proofs)", // raised by AtomicFlowManager
  ]),
  flowManager: parseAbi([
    ...structs,
    "function legState(bytes32 flowId, bytes32 bundleHash) view returns (uint8)",
    "function authorizeRefund(Flow flow, uint256 missingLegIndex, ImtProof timeoutProof)",
    "function claimRefund(bytes32 flowId, bytes bundle)",
  ]),
  attributes: parseAbi([
    ...structs,
    "function interopBundleSalt(bytes32 salt)",
    "function interopCallValue(uint256 value)",
    "function indirectCall(uint256 indirectCallMessageValue)",
    "function unbundlerAddress(bytes unbundler)",
    "function atomicBundle(FlowPreimage preimage, uint256 insertionHint)",
  ]),
  tokenVault: parseAbi([
    "function assetId(address token) view returns (bytes32)",
    "function registerToken(address token)",
    "function tokenAddress(bytes32 assetId) view returns (address)",
  ]),
  interopRootStorage: parseAbi([
    "function interopRoots(uint256 chainId, uint256 blockOrBatchNumber) view returns (bytes32 root, uint256 timestamp)",
  ]),
};

// ---------- ERC-7930 addresses ----------

function chainReference(chainId: bigint): Hex {
  const hex = chainId.toString(16);
  return `0x${hex.length % 2 ? "0" : ""}${hex}`;
}

/** A contract on a given chain, for example the recipient of `sendMessage`. */
export function erc7930(chainId: bigint, address: Address): Hex {
  const ref = chainReference(chainId);
  return concat(["0x00010000", toHex((ref.length - 2) / 2, { size: 1 }), ref, "0x14", address]);
}

/** A chain without an address: the destination of `sendBundle`. */
export function erc7930Chain(chainId: bigint): Hex {
  const ref = chainReference(chainId);
  return concat(["0x00010000", toHex((ref.length - 2) / 2, { size: 1 }), ref, "0x00"]);
}

/** An address without a chain: the target of each call in `sendBundle`. */
export function erc7930Address(address: Address): Hex {
  return concat(["0x000100000014", address]);
}

// ---------- ERC-7786 attributes ----------

export const attr = {
  /** Makes the bundle hash unique. Use a fresh salt for every send. */
  salt: (salt: Hex) => encodeFunctionData({ abi: abis.attributes, functionName: "interopBundleSalt", args: [salt] }),
  /** Base-token value delivered with a call on the destination chain. */
  callValue: (wei: bigint) =>
    encodeFunctionData({ abi: abis.attributes, functionName: "interopCallValue", args: [wei] }),
  /** Sends the call through the asset router on the source chain. Used for token transfers. */
  indirectCall: () => encodeFunctionData({ abi: abis.attributes, functionName: "indirectCall", args: [0n] }),
  /** The account allowed to execute or cancel the bundle's calls on the destination. */
  unbundler: (chainId: bigint, account: Address) =>
    encodeFunctionData({ abi: abis.attributes, functionName: "unbundlerAddress", args: [erc7930(chainId, account)] }),
  /** Marks the bundle as a leg of an atomic flow. */
  atomicBundle: (preimage: FlowPreimage, insertionHint: bigint) =>
    encodeFunctionData({ abi: abis.attributes, functionName: "atomicBundle", args: [preimage, insertionHint] }),
};

// ---------- Bundle hash preview ----------

type MessageArgs = [recipient: Hex, payload: Hex, attributes: Hex[]];
type BundleArgs = [destination: Hex, calls: { to: Hex; data: Hex; callAttributes: Hex[] }[], bundleAttributes: Hex[]];

/**
 * Runs `previewMessageHash` or `previewBundleHash` as an eth_call from the account that will send.
 * Both always revert with InteropPreviewHash(bundleHash); nothing is stored.
 */
async function previewHash(
  chain: Chain,
  sender: Address,
  functionName: "previewMessageHash" | "previewBundleHash",
  args: MessageArgs | BundleArgs
): Promise<Hex> {
  try {
    await publicClient(chain).simulateContract({
      account: sender,
      address: INTEROP_CENTER,
      abi: abis.interopCenter,
      functionName,
      args,
    });
  } catch (err) {
    const revert = (err as BaseError).walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName === "InteropPreviewHash") {
      return revert.data.args![0] as Hex;
    }
    throw err;
  }
  throw new Error(`${functionName} did not revert`);
}

/** Preview for `sendMessage(recipient, payload, attributes)`. */
export const previewMessageHash = (chain: Chain, sender: Address, args: MessageArgs) =>
  previewHash(chain, sender, "previewMessageHash", args);

/** Preview for `sendBundle(destination, calls, bundleAttributes)`. */
export const previewBundleHash = (chain: Chain, sender: Address, args: BundleArgs) =>
  previewHash(chain, sender, "previewBundleHash", args);

// ---------- Atomic flow ----------

export type FlowPreimage = {
  version: Hex;
  deadline: bigint;
  settlementLayerChainId: bigint;
  legBundleHashes: Hex[];
  legSourceChainIds: bigint[];
};

const preimageParams = parseAbiParameters(
  "(bytes1 version, uint64 deadline, uint256 settlementLayerChainId, bytes32[] legBundleHashes, uint256[] legSourceChainIds)"
);

/** Builds the flow from its legs. Leg hashes must be in ascending order; source chain IDs follow them. */
export function buildFlow(legs: { bundleHash: Hex; sourceChainId: bigint }[], deadline: bigint) {
  const sorted = [...legs].sort((a, b) => (BigInt(a.bundleHash) < BigInt(b.bundleHash) ? -1 : 1));
  const preimage: FlowPreimage = {
    version: "0x01",
    deadline,
    settlementLayerChainId: L1_CHAIN_ID, // atomic flows settle on L1 in v33
    legBundleHashes: sorted.map((l) => l.bundleHash),
    legSourceChainIds: sorted.map((l) => l.sourceChainId),
  };
  const flowId = keccak256(encodeAbiParameters(preimageParams, [preimage]));
  return { flowId, preimage };
}

/** The value a leg adds to its source chain's commitment tree. */
export function commitValue(flowId: Hex, bundleHash: Hex): bigint {
  const tag = keccak256(toHex("AtomicInterop.commit.v1")).slice(0, 10) as Hex;
  return BigInt(
    keccak256(encodeAbiParameters(parseAbiParameters("bytes4, bytes32, bytes32"), [tag, flowId, bundleHash]))
  );
}

/** Ethereum's current time: the timestamp of its latest block. */
export async function ethereumTime(): Promise<bigint> {
  return (await publicClient(l1).getBlock()).timestamp;
}

// ---------- Server RPCs for atomic interop ----------

type ServerProof = {
  batchNumber: number;
  settlementBlockNumber: number;
  provesAgainstBeginRoot: boolean;
  chainImtRoot: Hex;
  settlementProof: Hex[];
  leaf: { value: Hex; nextIndex: Hex; nextValue: Hex };
  imtLeafIndex: number;
  imtProof: Hex[];
};

// The zks_ methods aren't in viem's typed RPC schema, so they are called through the transport.
const zks = <T>(chain: Chain, method: string, params: unknown[]) =>
  http()({ chain }).request({ method, params }) as Promise<T>;

/** Insertion hint for `atomicBundle`, from the source chain's server. */
export async function insertionHint(chain: Chain, value: bigint): Promise<bigint> {
  const block = await publicClient(chain).getBlockNumber();
  const index = await zks<number | null>(chain, "zks_getImtLowNullifierIndex", [toHex(value), Number(block)]);
  if (index === null) throw new Error("no insertion hint: the value is already in the commitment tree");
  return BigInt(index);
}

/**
 * Asks the source chain's server for a proof. The server answers "not available" until the batch is
 * executed on Ethereum, so this retries for up to two minutes. Returns the proof in the on-chain
 * format, with the source chain ID added, and the Ethereum block its interop root belongs to.
 */
async function serverProof(source: Chain, method: string, params: unknown[]) {
  for (let attempt = 1; ; attempt++) {
    try {
      const proof = await zks<ServerProof | null>(source, method, params);
      if (!proof) throw new Error(`${method} returned no proof`);
      return {
        proof: {
          sourceChainId: BigInt(source.id),
          batchNumber: BigInt(proof.batchNumber),
          chainImtRoot: proof.chainImtRoot,
          provesAgainstBeginRoot: proof.provesAgainstBeginRoot,
          settlementProof: proof.settlementProof,
          leaf: {
            value: BigInt(proof.leaf.value),
            nextIndex: BigInt(proof.leaf.nextIndex),
            nextValue: BigInt(proof.leaf.nextValue),
          },
          imtLeafIndex: BigInt(proof.imtLeafIndex),
          imtProof: proof.imtProof,
        },
        settlementBlock: BigInt(proof.settlementBlockNumber),
      };
    } catch (err) {
      if (attempt >= 120 || !String((err as Error).message).includes("not available")) throw err;
      await sleep(1000);
    }
  }
}

/** Finality proof: the leg sent in block `sendBlock` of `source` is in its commitment tree. */
export const legCommittedProof = (source: Chain, value: bigint, sendBlock: bigint) =>
  serverProof(source, "zks_getImtInclusionProof", [toHex(value), Number(sendBlock)]);

/**
 * Timeout proof: the leg is not in `source`'s commitment tree at the start of a batch executed on
 * Ethereum after `deadline`. Starts from the latest batch and moves forward until one qualifies.
 */
export async function legMissingProof(source: Chain, value: bigint, deadline: bigint) {
  for (let batch = await zks<number>(source, "zks_batchNumber", []); ; batch++) {
    const result = await serverProof(source, "zks_getImtNonInclusionProof", [toHex(value), batch]);
    const settledAt = (await publicClient(l1).getBlock({ blockNumber: result.settlementBlock })).timestamp;
    if (settledAt > deadline) return result;
  }
}

/** Waits until `chain` has imported the interop root of Ethereum block `settlementBlock`. */
export async function waitForInteropRoot(chain: Chain, settlementBlock: bigint) {
  for (let attempt = 1; ; attempt++) {
    const [root] = await publicClient(chain).readContract({
      address: INTEROP_ROOT_STORAGE,
      abi: abis.interopRootStorage,
      functionName: "interopRoots",
      args: [L1_CHAIN_ID, settlementBlock],
    });
    if (BigInt(root) !== 0n) return;
    if (attempt >= 120)
      throw new Error(`chain ${chain.id} has not imported the interop root of Ethereum block ${settlementBlock}`);
    await sleep(1000);
  }
}

// ---------- Reading the sent bundle ----------

const bundleParam = getAbiItem({ abi: abis.interopCenter, name: "InteropBundleSent" }).inputs[2];

/** Returns the sent bundle (ABI-encoded), its hash and the send block from the send transaction's receipt. */
export function sentBundle(receipt: TransactionReceipt) {
  const [event] = parseEventLogs({ abi: abis.interopCenter, logs: receipt.logs, eventName: "InteropBundleSent" });
  const bundle = encodeAbiParameters([bundleParam], [event.args.interopBundle]);
  return { bundle, bundleHash: event.args.interopBundleHash, block: receipt.blockNumber };
}

export const BundleStatus = ["Unreceived", "Verified", "FullyExecuted", "Unbundled"];
export const LegState = ["Unset", "Committed", "Revertable", "Reverted"];

// ---------- Contract calls: each one sends a single call and throws if it reverts ----------

export type Flow = { flowId: Hex; preimage: FlowPreimage };
export type ImtProof = Awaited<ReturnType<typeof legCommittedProof>>["proof"];
export type Finality = { flow: Flow; proofs: ImtProof[] };

async function confirmed(chain: Chain, hash: Hex, name: string) {
  const receipt = await publicClient(chain).waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${name} reverted in tx ${hash}`);
  return receipt;
}

/** The interop fee per call, in the source chain's base token. `msg.value` must include it exactly. */
export const interopFee = (chain: Chain) =>
  publicClient(chain).readContract({
    address: INTEROP_CENTER,
    abi: abis.interopCenter,
    functionName: "interopProtocolFee",
  });

/** `InteropCenter.sendMessage`. Returns the sent bundle, its hash and the send block. */
export async function sendMessage(chain: Chain, sender: Account, args: MessageArgs, value: bigint) {
  const hash = await walletClient(chain, sender).writeContract({
    address: INTEROP_CENTER,
    abi: abis.interopCenter,
    functionName: "sendMessage",
    args,
    value,
  });
  return sentBundle(await confirmed(chain, hash, "sendMessage"));
}

/** `InteropCenter.sendBundle`. Returns the sent bundle, its hash and the send block. */
export async function sendBundle(chain: Chain, sender: Account, args: BundleArgs, value: bigint) {
  const hash = await walletClient(chain, sender).writeContract({
    address: INTEROP_CENTER,
    abi: abis.interopCenter,
    functionName: "sendBundle",
    args,
    value,
  });
  return sentBundle(await confirmed(chain, hash, "sendBundle"));
}

/** `L2InteropHandler.executeAtomicBundle`. Returns the transaction hash. */
export async function executeAtomicBundle(chain: Chain, account: Account, bundle: Hex, finality: Finality) {
  const hash = await walletClient(chain, account).writeContract({
    address: INTEROP_HANDLER,
    abi: abis.interopHandler,
    functionName: "executeAtomicBundle",
    args: [bundle, finality],
  });
  await confirmed(chain, hash, "executeAtomicBundle");
  return hash;
}

/** Simulates `executeAtomicBundle` without sending it and returns the name of the error it reverts with. */
export async function executeAtomicBundleError(chain: Chain, account: Account, bundle: Hex, finality: Finality) {
  try {
    await publicClient(chain).simulateContract({
      account,
      address: INTEROP_HANDLER,
      abi: abis.interopHandler,
      functionName: "executeAtomicBundle",
      args: [bundle, finality],
    });
  } catch (err) {
    const revert = (err as BaseError).walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) return revert.data?.errorName;
    throw err;
  }
  return "nothing: it would succeed";
}

/** `AtomicFlowManager.authorizeRefund`, on the chain the legs to refund were sent from. */
export async function authorizeRefund(
  chain: Chain,
  account: Account,
  flow: Flow,
  missingLegIndex: bigint,
  timeoutProof: ImtProof
) {
  const hash = await walletClient(chain, account).writeContract({
    address: ATOMIC_FLOW_MANAGER,
    abi: abis.flowManager,
    functionName: "authorizeRefund",
    args: [flow, missingLegIndex, timeoutProof],
  });
  await confirmed(chain, hash, "authorizeRefund");
}

/** `AtomicFlowManager.claimRefund`: returns a leg's funds to its sender, whoever calls it. */
export async function claimRefund(chain: Chain, account: Account, flowId: Hex, bundle: Hex) {
  const hash = await walletClient(chain, account).writeContract({
    address: ATOMIC_FLOW_MANAGER,
    abi: abis.flowManager,
    functionName: "claimRefund",
    args: [flowId, bundle],
  });
  await confirmed(chain, hash, "claimRefund");
}

/** `AtomicFlowManager.legState` on the leg's source chain, as a name. */
export async function legState(chain: Chain, flowId: Hex, bundleHash: Hex) {
  const state = await publicClient(chain).readContract({
    address: ATOMIC_FLOW_MANAGER,
    abi: abis.flowManager,
    functionName: "legState",
    args: [flowId, bundleHash],
  });
  return LegState[state];
}

/** `L2InteropHandler.bundleStatus` on the destination chain, as a name. */
export async function bundleStatus(chain: Chain, bundleHash: Hex) {
  const status = await publicClient(chain).readContract({
    address: INTEROP_HANDLER,
    abi: abis.interopHandler,
    functionName: "bundleStatus",
    args: [bundleHash],
  });
  return BundleStatus[status];
}
