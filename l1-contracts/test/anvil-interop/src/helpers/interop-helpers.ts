/**
 * Interop bundle and message helpers.
 *
 * Provides RPC wrappers for InteropCenter.sendBundle / sendMessage and
 * InteropHandler.executeBundle / verifyBundle / unbundleBundle, along with
 * ERC-7786 attribute encoding and contract deployment utilities.
 */

import type { providers, BigNumber } from "ethers";
import { Contract, ethers, Wallet } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  INTEROP_SEND_BUNDLE_GAS_LIMIT,
  L2_INTEROP_HANDLER_ADDR,
} from "../core/const";
import { encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "../core/data-encoding";
import { buildMockInteropProof } from "../core/utils";
import { encodeEvmChain, encodeEvmAddress } from "./erc7930";

const abiCoder = ethers.utils.defaultAbiCoder;

/** IERC7786Attributes interface — used for attribute encoding via encodeFunctionData. */
const erc7786Iface = new ethers.utils.Interface(getAbi("IERC7786Attributes"));

// ── ERC-7786 attribute encoding ────────────────────────────────
// Uses IERC7786Attributes.encodeFunctionData so selectors and parameter
// encoding are derived from the Solidity interface — no manual hex.

/** Encode an interopCallValue attribute (direct call: transfers base token value). */
export function interopCallValueAttr(amount: BigNumber): string {
  return erc7786Iface.encodeFunctionData("interopCallValue", [amount]);
}

/** Encode an indirectCall attribute (indirect call: routes through asset router). */
export function indirectCallAttr(callValue?: BigNumber): string {
  return erc7786Iface.encodeFunctionData("indirectCall", [callValue || 0]);
}

/** Encode an executionAddress bundle attribute. */
export function executionAddressAttr(address: string): string {
  return erc7786Iface.encodeFunctionData("executionAddress", [encodeEvmAddress(address)]);
}

/** Encode an unbundlerAddress bundle attribute. */
export function unbundlerAddressAttr(address: string): string {
  return erc7786Iface.encodeFunctionData("unbundlerAddress", [encodeEvmAddress(address)]);
}

// ── Token transfer data encoding ───────────────────────────────

/**
 * Encode the secondBridgeData for an ERC20 token transfer via L2AssetRouter.
 * This is the `data` field of an indirect call starter targeting L2_ASSET_ROUTER_ADDR.
 */
export function getTokenTransferData(assetId: string, amount: BigNumber, recipientAddress: string): string {
  const transferData = encodeBridgeBurnData(amount, recipientAddress, ethers.constants.AddressZero);
  return encodeAssetRouterBridgehubDepositData(assetId, transferData);
}

// ── InteropCenter.sendBundle wrapper ───────────────────────────

export interface CallStarter {
  to: string; // ERC-7930 encoded destination address
  data: string; // calldata
  callAttributes: string[]; // ERC-7786 per-call attributes
}

export interface SendBundleOptions {
  sourceProvider: providers.JsonRpcProvider;
  destinationChainId: number;
  callStarters: CallStarter[];
  bundleAttributes?: string[];
  value?: BigNumber;
  gasLimit?: number;
}

export interface InteropSendResult {
  txHash: string;
  receipt: ethers.providers.TransactionReceipt;
  /** Raw decoded InteropBundle struct from the InteropBundleSent event (ethers tuple). */
  interopBundle: unknown;
  /** ABI-encoded bundle data, ready for executeBundle / verifyBundle / unbundleBundle. */
  bundleData: string;
  bundleHash: string;
}

/**
 * Send an interop bundle via InteropCenter.sendBundle on the source chain.
 * Returns the tx receipt and the extracted InteropBundle struct.
 */
export async function sendInteropBundle(options: SendBundleOptions): Promise<InteropSendResult> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, options.sourceProvider);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);

  const destinationChainIdBytes = encodeEvmChain(options.destinationChainId);
  const tx = await interopCenter.sendBundle(
    destinationChainIdBytes,
    options.callStarters,
    options.bundleAttributes || [],
    {
      gasLimit: options.gasLimit || INTEROP_SEND_BUNDLE_GAS_LIMIT,
      value: options.value || 0,
    }
  );
  const receipt = await tx.wait();

  // Extract InteropBundleSent event
  let interopBundle: unknown = null;
  let bundleHash: string = ethers.constants.HashZero;
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenter.interface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed?.name === "InteropBundleSent") {
        interopBundle = parsed.args["interopBundle"];
        bundleHash = parsed.args["interopBundleHash"];
        break;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  if (!interopBundle) {
    throw new Error("InteropBundleSent event not found in source transaction receipt");
  }

  const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

  return { txHash: tx.hash, receipt, interopBundle, bundleData, bundleHash };
}

// ── InteropCenter.sendMessage wrapper ──────────────────────────

export interface SendMessageOptions {
  sourceProvider: providers.JsonRpcProvider;
  recipient: string; // ERC-7930 encoded recipient
  payload: string;
  attributes: string[];
  value?: BigNumber;
  gasLimit?: number;
}

/**
 * Send a single interop message via InteropCenter.sendMessage on the source chain.
 * Returns the tx receipt and the extracted InteropBundle struct (sendMessage wraps into a bundle).
 */
export async function sendInteropMessage(options: SendMessageOptions): Promise<InteropSendResult> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, options.sourceProvider);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);

  const tx = await interopCenter.sendMessage(options.recipient, options.payload, options.attributes, {
    gasLimit: options.gasLimit || INTEROP_SEND_BUNDLE_GAS_LIMIT,
    value: options.value || 0,
  });
  const receipt = await tx.wait();

  // Extract InteropBundleSent event
  let interopBundle: unknown = null;
  let bundleHash: string = ethers.constants.HashZero;
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenter.interface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed?.name === "InteropBundleSent") {
        interopBundle = parsed.args["interopBundle"];
        bundleHash = parsed.args["interopBundleHash"];
        break;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  if (!interopBundle) {
    throw new Error("InteropBundleSent event not found in sendMessage receipt");
  }

  const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

  return { txHash: tx.hash, receipt, interopBundle, bundleData, bundleHash };
}

// ── InteropHandler.executeBundle wrapper ───────────────────────

/**
 * Execute an interop bundle on the destination chain via InteropHandler.executeBundle.
 * Uses a mock proof (verification is bypassed in the Anvil test environment).
 */
export async function executeBundle(
  destProvider: providers.JsonRpcProvider,
  bundleData: string,
  sourceChainId: number,
  gasLimit?: number
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);
  const mockProof = buildMockInteropProof(sourceChainId);

  const tx = await interopHandler.executeBundle(bundleData, mockProof, {
    gasLimit: gasLimit || DEFAULT_TX_GAS_LIMIT,
  });
  return tx.wait();
}

/**
 * Verify a bundle on the destination chain via InteropHandler.verifyBundle.
 * Uses a mock proof.
 */
export async function verifyBundle(
  destProvider: providers.JsonRpcProvider,
  bundleData: string,
  sourceChainId: number,
  signerKey?: string
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(signerKey || ANVIL_DEFAULT_PRIVATE_KEY, destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);
  const mockProof = buildMockInteropProof(sourceChainId);

  const tx = await interopHandler.verifyBundle(bundleData, mockProof, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  return tx.wait();
}

/**
 * Unbundle a bundle on the destination chain via InteropHandler.unbundleBundle.
 */
export async function unbundleBundle(
  destProvider: providers.JsonRpcProvider,
  bundleData: string,
  callStatuses: number[],
  signerKey?: string
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(signerKey || ANVIL_DEFAULT_PRIVATE_KEY, destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);

  const tx = await interopHandler.unbundleBundle(bundleData, callStatuses, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  return tx.wait();
}

/**
 * Query bundle status from InteropHandler.
 */
export async function getBundleStatus(provider: providers.JsonRpcProvider, bundleHash: string): Promise<number> {
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), provider);
  const result = await interopHandler.bundleStatus(bundleHash);
  return typeof result === "number" ? result : result.toNumber();
}

/**
 * Query individual call status from InteropHandler.
 */
export async function getCallStatus(
  provider: providers.JsonRpcProvider,
  bundleHash: string,
  callIndex: number
): Promise<number> {
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), provider);
  const result = await interopHandler.callStatus(bundleHash, callIndex);
  return typeof result === "number" ? result : result.toNumber();
}

/**
 * Get the interop protocol fee from InteropCenter.
 */
export async function getInteropProtocolFee(provider: providers.JsonRpcProvider): Promise<BigNumber> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.interopProtocolFee();
}

/**
 * Deploy a DummyInteropRecipient contract on a chain.
 * This contract implements IERC7786Recipient.receiveMessage and can receive ETH.
 * Required as the destination for direct-call bundles (value transfers).
 * Source: contracts/dev-contracts/test/DummyInteropRecipient.sol
 */
export async function deployDummyInteropRecipient(
  provider: providers.JsonRpcProvider,
  signerKey?: string
): Promise<string> {
  const wallet = new Wallet(signerKey || ANVIL_DEFAULT_PRIVATE_KEY, provider);
  const factory = new ethers.ContractFactory(
    getAbi("DummyInteropRecipient"),
    getCreationBytecode("DummyInteropRecipient"),
    wallet
  );
  const contract = await factory.deploy();
  await contract.deployed();
  return contract.address;
}

/**
 * Deploy a minimal contract that reverts on any call.
 * Used to create deterministic failing calls in unbundle tests.
 *
 * Bytecode: PUSH1 0x00 PUSH1 0x00 REVERT (runtime: 0x60006000fd)
 * Init code: deploys the revert bytecode as runtime code.
 */
export async function deployRevertingContract(
  provider: providers.JsonRpcProvider,
  signerKey?: string
): Promise<string> {
  const wallet = new Wallet(signerKey || ANVIL_DEFAULT_PRIVATE_KEY, provider);
  // Init code that returns 0x60006000fd as the deployed runtime code
  // PUSH5 0x60006000fd PUSH1 0x00 MSTORE PUSH1 0x05 PUSH1 0x1b RETURN
  const initCode = "0x6460006000fd6000526005601bf3";
  const tx = await wallet.sendTransaction({ data: initCode });
  const receipt = await tx.wait();
  if (!receipt.contractAddress) throw new Error("Failed to deploy reverting contract");
  return receipt.contractAddress;
}
