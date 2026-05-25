/**
 * Helpers for the dummy-interop atomicity stack.
 *
 * Deploys `MockL2MessageVerification` (reused on L1 — same interface) + `L1FlowLinker` on L1
 * and one `L2FlowEscrow` per participating L2. Constructs `CommitProof` / `ExecuteParams`
 * payloads for the linker entries. Cross-chain inclusion proofs are mocked: the linker
 * accepts any proof because the L1 message verifier always returns true.
 */

import { BigNumber, Contract, ContractFactory, Wallet, ethers, providers } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_TO_L1_MESSENGER_ADDR } from "../core/const";

/** Mirror of the Solidity `SendSpec` struct in `IDummyFlow.sol`. */
export interface SendSpec {
  destChainId: BigNumber;
  recipient: string;
  token: string;
  amount: BigNumber;
  followupTo: string;
  followupData: string;
}

/** Mirror of `Participant`. */
export interface Participant {
  chainId: BigNumber;
  escrow: string;
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
  "tuple(uint256 destChainId, address recipient, address token, uint256 amount, address followupTo, bytes followupData)";

// COMMIT_LOG_TAG = bytes4(keccak256("DummyFlow.commit.v1"))
export const COMMIT_LOG_TAG = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("DummyFlow.commit.v1")).slice(0, 10);

/**
 * Deploy `MockL2MessageVerification` + `L1FlowLinker` on L1. The mock verifier accepts any
 * inclusion proof — fine for anvil tests where the real cross-chain settlement pipeline
 * doesn't run.
 */
export async function deployL1FlowStack(l1Provider: providers.JsonRpcProvider, l1Bridgehub: string): Promise<{
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
 * Deploy one `L2FlowEscrow` on each provided L2, wired to the same `_l1LinkerAddress`.
 * Returns a map from chainId → deployed escrow contract.
 */
export async function deployL2EscrowsForChains(
  l2Providers: Array<{ chainId: number; provider: providers.JsonRpcProvider }>,
  _l1LinkerAddress: string
): Promise<Record<number, Contract>> {
  const out: Record<number, Contract> = {};
  await Promise.all(
    l2Providers.map(async ({ chainId, provider }) => {
      const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
      const factory = new ContractFactory(getAbi("L2FlowEscrow"), getCreationBytecode("L2FlowEscrow"), wallet);
      const escrow = await factory.deploy();
      await escrow.deployed();
      await (await escrow.initialize(_l1LinkerAddress)).wait();
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
  // The sender comes from the indexed topic; decode the data payload (the message bytes).
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

/** Convenience: helpers to make a `SendSpec` that's receive-only / no followup. */
export function buildSendSpec(args: {
  destChainId: number;
  recipient: string;
  token: string;
  amount: BigNumber;
  followupTo?: string;
  followupData?: string;
}): SendSpec {
  return {
    destChainId: BigNumber.from(args.destChainId),
    recipient: args.recipient,
    token: args.token,
    amount: args.amount,
    followupTo: args.followupTo ?? ethers.constants.AddressZero,
    followupData: args.followupData ?? "0x",
  };
}
