/**
 * Helpers for the dummy-interop atomicity stack.
 *
 * Deploys `MockL2MessageVerification` (reused on L1 — same interface) + `L1FlowLinker` on L1
 * and one `L2FlowEscrow` per participating L2. Computes `flowId` from sorted spec hashes,
 * constructs `CommitProof` / `ExecuteParams` payloads for the linker entries. Cross-chain
 * inclusion proofs are mocked: the linker accepts any proof because the L1 message verifier
 * always returns true.
 */

import type { Contract, providers } from "ethers";
import { BigNumber, ContractFactory, Wallet, ethers } from "ethers";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_TO_L1_MESSENGER_ADDR,
} from "../core/const";

/** Mirror of the Solidity `SendSpec` struct in `IDummyFlow.sol`. */
export interface SendSpec {
  destChainId: BigNumber;
  recipient: string;
  originChainId: BigNumber;
  originToken: string;
  amount: BigNumber;
  erc20Data: string;
  depositor: string;
}

/** Mirror of `CommitProof`. */
export interface CommitProof {
  chainId: BigNumber;
  blockOrBatchNumber: BigNumber;
  messageIndex: BigNumber;
  message: {
    txNumberInBatch: number;
    sender: string;
    data: string;
  };
  merkleProof: string[];
}

/** Mirror of `ExecuteParams`. */
export interface ExecuteParams {
  mintValue: BigNumber;
  l2GasLimit: BigNumber;
  l2GasPerPubdataByteLimit: BigNumber;
  refundRecipient: string;
}

const SOLIDITY_SEND_SPEC_TUPLE =
  "tuple(uint256 destChainId, address recipient, uint256 originChainId, address originToken, " +
  "uint256 amount, bytes erc20Data, address depositor)";

// COMMIT_LOG_TAG = bytes4(keccak256("DummyFlow.commit.v2"))
export const COMMIT_LOG_TAG = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("DummyFlow.commit.v2")).slice(0, 10);

/**
 * Compute a spec hash matching `keccak256(abi.encode(sendSpec))` on chain.
 */
export function computeSpecHash(spec: SendSpec): string {
  const encoded = ethers.utils.defaultAbiCoder.encode([SOLIDITY_SEND_SPEC_TUPLE], [spec]);
  return ethers.utils.keccak256(encoded);
}

/**
 * Compute the flowId: `keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`.
 * Spec-hash sort order matches the linker's `_sortHashes` (lexicographic ascending on
 * bytes32); chain ids must be passed ascending-sorted with no duplicates (the linker's
 * `registerFlow` enforces this).
 *
 * Binding the chain set + deadline into the hash prevents a frontrunning attacker from
 * racing `registerFlow` with the same spec set but a different chain set or earlier
 * deadline.
 */
export function computeFlowId(
  specs: SendSpec[],
  sortedChainIds: ReadonlyArray<number | BigNumber>,
  deadline: number | BigNumber
): string {
  const hashes = specs.map(computeSpecHash);
  const sortedHashes = [...hashes].sort((a, b) =>
    a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0
  );
  const encoded = ethers.utils.defaultAbiCoder.encode(
    ["bytes32[]", "uint256[]", "uint64"],
    [sortedHashes, sortedChainIds.map((c) => BigNumber.from(c)), BigNumber.from(deadline)]
  );
  return ethers.utils.keccak256(encoded);
}

/**
 * Deploy `MockL2MessageVerification` + `L1FlowLinker` on L1. The mock verifier accepts any
 * inclusion proof — fine for anvil tests where the real cross-chain settlement pipeline
 * doesn't run.
 */
export async function deployL1FlowStack(
  l1Provider: providers.JsonRpcProvider,
  l1Bridgehub: string
): Promise<{
  linker: Contract;
  mockVerifier: Contract;
}> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

  const mockVerifierFactory = new ContractFactory(
    getAbi("MockL2MessageVerification"),
    getCreationBytecode("MockL2MessageVerification"),
    wallet
  );
  const mockVerifier = await mockVerifierFactory.deploy();
  await mockVerifier.deployed();

  const linkerFactory = new ContractFactory(getAbi("L1FlowLinker"), getCreationBytecode("L1FlowLinker"), wallet);
  const linker = await linkerFactory.deploy(l1Bridgehub, mockVerifier.address);
  await linker.deployed();

  return { linker, mockVerifier };
}

/**
 * Whether the contract at `address` exposes the function with 4-byte `selector` — detected by
 * scanning its runtime code for the selector (no eth_call, so no error to swallow). Lets the escrow
 * deployer detect whether a pre-generated chain state predates the AR's atomic-flow additions.
 */
async function hasSelector(provider: providers.JsonRpcProvider, address: string, selector: string): Promise<boolean> {
  const code: string = (await provider.getCode(address)).toLowerCase();
  return code.includes(selector.slice(2).toLowerCase());
}

/**
 * Deploy one `L2FlowEscrow` on each provided L2, wired to the same `_l1LinkerAddress`.
 * Each chain may override the AR/NTV the escrow drives — defaults are the system
 * predeploys at `L2_ASSET_ROUTER_ADDR` / `L2_NATIVE_TOKEN_VAULT_ADDR`, which is what
 * the anvil tests use. For real testnet deploys, pass the userspace AR/NTV addresses.
 *
 * Returns a map from chainId → deployed escrow contract.
 */
export async function deployL2EscrowsForChains(
  l2Providers: Array<{
    chainId: number;
    provider: providers.JsonRpcProvider;
    /** Defaults to the system L2_ASSET_ROUTER_ADDR if omitted. */
    assetRouter?: string;
    /** Defaults to the system L2_NATIVE_TOKEN_VAULT_ADDR if omitted. */
    nativeTokenVault?: string;
  }>,
  _l1LinkerAddress: string
): Promise<Record<number, Contract>> {
  const out: Record<number, Contract> = {};
  await Promise.all(
    l2Providers.map(async ({ chainId, provider, assetRouter, nativeTokenVault }) => {
      const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
      const ar = assetRouter ?? L2_ASSET_ROUTER_ADDR;
      const ntv = nativeTokenVault ?? L2_NATIVE_TOKEN_VAULT_ADDR;

      // The pre-generated chain states were dumped before the AR's atomic-flow additions
      // (`atomicFlowManager` / `setAtomicFlowManager` / the `isAtomicFlowManager` exception in
      // `onlyAssetRouterCounterpartOrSelf`). The dummy flow registers its escrow in that slot so the
      // escrow can drive `initiateIndirectCall` (source burn) and `finalizeDeposit` (destination mint),
      // so refresh the AR runtime code in place to the freshly-built bytecode. Code-only upgrade: the
      // atomic-flow additions only append the `atomicFlowManager` slot (reads as 0 in the old state,
      // exactly what `setAtomicFlowManager` requires); no existing slot is reordered or overwritten.
      // This is the same `anvil_setCode` built-in-refresh pattern the bundle-model deployer uses.
      if (!(await hasSelector(provider, ar, ethers.utils.id("setAtomicFlowManager(address)").slice(0, 10)))) {
        await provider.send("anvil_setCode", [ar, getBytecode("L2AssetRouter")]);
      }

      const factory = new ContractFactory(getAbi("L2FlowEscrow"), getCreationBytecode("L2FlowEscrow"), wallet);
      const escrow = await factory.deploy();
      await escrow.deployed();
      await (await escrow.initialize(_l1LinkerAddress, ar, ntv)).wait();
      out[chainId] = escrow;
    })
  );
  return out;
}

/**
 * Build a `CommitProof` from the L2 receipt of a `commitSend` call. We pull the L2→L1
 * message bytes off the `L1MessageSent` event emitted by `L2_TO_L1_MESSENGER` and pack
 * the rest as a mock proof (the L1 verifier always returns true on anvil).
 */
export function buildCommitProofFromReceipt(
  chainId: number,
  receipt: ethers.providers.TransactionReceipt,
  escrowAddress: string
): CommitProof {
  // L1MessageSent(address indexed sender, bytes32 indexed hash, bytes message)
  const messageSentTopic = ethers.utils.id("L1MessageSent(address,bytes32,bytes)");
  const log = receipt.logs.find(
    (l) => l.topics[0] === messageSentTopic && l.address.toLowerCase() === L2_TO_L1_MESSENGER_ADDR.toLowerCase()
  );
  if (!log) {
    throw new Error(
      `No L1MessageSent event from L2_TO_L1_MESSENGER in receipt for chain ${chainId} (escrow ${escrowAddress})`
    );
  }
  const senderFromTopic = ethers.utils.getAddress("0x" + log.topics[1].slice(26));
  const [data] = ethers.utils.defaultAbiCoder.decode(["bytes"], log.data);
  if (senderFromTopic.toLowerCase() !== escrowAddress.toLowerCase()) {
    throw new Error(`L1MessageSent sender ${senderFromTopic} != escrow ${escrowAddress}`);
  }

  return {
    chainId: BigNumber.from(chainId),
    blockOrBatchNumber: BigNumber.from(1),
    messageIndex: BigNumber.from(0),
    message: {
      txNumberInBatch: 0,
      sender: escrowAddress,
      data,
    },
    merkleProof: [ethers.constants.HashZero],
  };
}

/** Encode a `SendSpec` as its Solidity tuple form for direct calldata construction. */
export function encodeSendSpec(spec: SendSpec): string {
  return ethers.utils.defaultAbiCoder.encode([SOLIDITY_SEND_SPEC_TUPLE], [spec]);
}

/** Build an `ExecuteParams` for a given mintValue with sensible defaults. */
export function buildExecuteParams(
  mintValue: BigNumber,
  refundRecipient: string,
  opts?: { l2GasLimit?: BigNumber; l2GasPerPubdataByteLimit?: BigNumber }
): ExecuteParams {
  return {
    mintValue,
    l2GasLimit: opts?.l2GasLimit ?? BigNumber.from(2_000_000),
    l2GasPerPubdataByteLimit: opts?.l2GasPerPubdataByteLimit ?? BigNumber.from(800),
    refundRecipient,
  };
}

/** Convenience constructor for a `SendSpec` with reasonable defaults. */
export function buildSendSpec(args: {
  destChainId: number;
  recipient: string;
  originChainId: number;
  originToken: string;
  amount: BigNumber;
  depositor: string;
  erc20Data?: string;
}): SendSpec {
  return {
    destChainId: BigNumber.from(args.destChainId),
    recipient: args.recipient,
    originChainId: BigNumber.from(args.originChainId),
    originToken: args.originToken,
    amount: args.amount,
    erc20Data: args.erc20Data ?? "0x",
    depositor: args.depositor,
  };
}

/**
 * Build the `erc20Data` blob the NTV expects when deploying a bridged shim on first
 * arrival. Mirrors `DataEncoding.encodeTokenData(chainId, name, symbol, decimals)`:
 *   NEW_ENCODING_VERSION (0x01) || abi.encode(chainId, abi.encode(name), abi.encode(symbol), abi.encode(decimals))
 */
export function encodeErc20Data(originChainId: number, name: string, symbol: string, decimals: number): string {
  const nameBytes = ethers.utils.defaultAbiCoder.encode(["string"], [name]);
  const symbolBytes = ethers.utils.defaultAbiCoder.encode(["string"], [symbol]);
  const decimalsBytes = ethers.utils.defaultAbiCoder.encode(["uint8"], [decimals]);
  const inner = ethers.utils.defaultAbiCoder.encode(
    ["uint256", "bytes", "bytes", "bytes"],
    [originChainId, nameBytes, symbolBytes, decimalsBytes]
  );
  return "0x01" + inner.slice(2);
}
