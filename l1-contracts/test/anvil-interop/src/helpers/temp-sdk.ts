import { createViemClient, createViemSdk } from "@matterlabs/zksync-js/viem";
import type { BytesLike, providers } from "ethers";
import { Contract, ethers } from "ethers";
import { createPublicClient, createWalletClient, http } from "viem";
import type { Address, Chain, Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { getAbi } from "../core/contracts";
import { L2_BRIDGEHUB_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR, L2_TO_L1_MESSENGER_ADDR } from "../core/const";
import type { FinalizeWithdrawalParams } from "../core/types";

const INTEROP_BUNDLE_ABI =
  "tuple(bytes1 version, uint256 sourceChainId, uint256 destinationChainId, bytes32 destinationBaseTokenAssetId, bytes32 interopBundleSalt, tuple(bytes1 version, bool shadowAccount, address to, address from, uint256 value, bytes data)[] calls, (bytes executionAddress, bytes unbundlerAddress, bool useFixedFee) bundleAttributes)";

const DEFAULT_LIVE_INTEROP_PROOF_TYPE = "messageRoot";
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const PROOF_METADATA_HEX_LENGTH = 66;
const PROOF_METADATA_PREFIX_HEX_LENGTH = 10;
const PROOF_METADATA_TRAILING_ZERO_HEX_LENGTH = 56;
const PROOF_METADATA_VERSION = 1;
const LIVE_CHAIN_NATIVE_CURRENCY = { name: "Ether", symbol: "ETH", decimals: 18 } as const;
const abiCoder = ethers.utils.defaultAbiCoder;

export interface LiveZksyncSdkParams {
  privateKey: string;
  l1RpcUrl: string;
  l1ChainId: number;
  l2RpcUrl: string;
  l2ChainId: number;
  l2Name: string;
}

export interface LiveInteropProof {
  rawData: string;
  proofDecoded: MessageInclusionProof;
}

export interface MessageInclusionProof {
  chainId: number;
  l1BatchNumber: number;
  l2MessageIndex: number;
  message: [number, string, string];
  proof: string[];
}

interface InteropBundleData extends LiveInteropProof {
  l1BatchNumber: number;
  gatewayBlockNumber?: number;
}

type NumericRpcValue = number | string;

interface ZkReceiptLog {
  address: string;
  topics: string[];
  data: string;
}

interface L2ToL1ReceiptLog {
  sender: string;
  transactionIndex?: NumericRpcValue;
}

interface RawZkReceipt {
  transactionHash?: string;
  blockNumber: NumericRpcValue;
  logs?: ZkReceiptLog[];
  l1BatchTxIndex?: NumericRpcValue;
  l2ToL1Logs?: L2ToL1ReceiptLog[];
}

interface ZkReceipt {
  transactionHash: string;
  blockNumber: number;
  logs: ZkReceiptLog[];
  l1BatchTxIndex?: NumericRpcValue;
  l2ToL1Logs?: L2ToL1ReceiptLog[];
}

interface LogProof {
  batchNumber: number | string;
  gatewayBlockNumber?: number | string;
  id: number | string;
  proof: string[];
}

interface LiveFinalizeWithdrawalParams {
  l1BatchNumber: number;
  l2MessageIndex: number;
  l2TxNumberInBlock: number;
  gatewayBlockNumber?: number;
  message: string;
  sender: string;
  proof: string[];
}

export function asViemPrivateKey(privateKey: string, label = "private key"): Hex {
  if (!ethers.utils.isHexString(privateKey, 32)) {
    throw new Error(`${label} must be a 32-byte 0x-prefixed private key`);
  }
  return privateKey as Hex;
}

export function asViemAddress(address: string, label: string): Address {
  if (!ethers.utils.isAddress(address)) {
    throw new Error(`${label} must be an EVM address, got ${address}`);
  }
  return ethers.utils.getAddress(address) as Address;
}

export function makeLiveViemChain(chainId: number, name: string, rpcUrl: string): Chain {
  return {
    id: chainId,
    name,
    nativeCurrency: LIVE_CHAIN_NATIVE_CURRENCY,
    rpcUrls: {
      default: { http: [rpcUrl] },
    },
  };
}

export function createLiveZksyncSdk(params: LiveZksyncSdkParams) {
  const account = privateKeyToAccount(asViemPrivateKey(params.privateKey));
  const l1Chain = makeLiveViemChain(params.l1ChainId, "Live Interop L1", params.l1RpcUrl);
  const l2Chain = makeLiveViemChain(params.l2ChainId, params.l2Name, params.l2RpcUrl);

  const l1 = createPublicClient({ chain: l1Chain, transport: http(params.l1RpcUrl) });
  const l2 = createPublicClient({ chain: l2Chain, transport: http(params.l2RpcUrl) });
  const l1Wallet = createWalletClient({ account, chain: l1Chain, transport: http(params.l1RpcUrl) });
  const l2Wallet = createWalletClient({ account, chain: l2Chain, transport: http(params.l2RpcUrl) });
  const client = createViemClient({ l1, l2, l1Wallet, l2Wallet });

  return { account, client, sdk: createViemSdk(client) };
}

export async function waitForLiveInteropProof(
  sourceProvider: providers.JsonRpcProvider,
  destProvider: providers.JsonRpcProvider,
  sourceTxHash: BytesLike,
  sourceChainId: number,
  index = 0,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<LiveInteropProof> {
  const txHash = ethers.utils.hexlify(sourceTxHash);
  const receipt = await getZkReceipt(sourceProvider, txHash);
  await waitUntilBlockFinalized(sourceProvider, receipt.blockNumber, timeoutMs);

  const proofType = process.env.LIVE_INTEROP_PROOF_TYPE?.trim() || DEFAULT_LIVE_INTEROP_PROOF_TYPE;
  const bundleData = await getInteropBundleData(sourceProvider, receipt, index, timeoutMs, proofType);
  await waitUntilBatchExecutedOnGateway(sourceChainId, bundleData.l1BatchNumber, timeoutMs);
  await waitForInteropRootNonZero(
    destProvider,
    bundleData.gatewayBlockNumber ?? getGWBlockNumber(bundleData.proofDecoded.proof),
    timeoutMs
  );
  return {
    rawData: bundleData.rawData,
    proofDecoded: bundleData.proofDecoded,
  };
}

export async function waitForLiveFinalizeWithdrawalParams(
  provider: providers.JsonRpcProvider,
  txHash: BytesLike,
  chainId: number,
  index = 0,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<FinalizeWithdrawalParams> {
  const receipt = await getZkReceipt(provider, ethers.utils.hexlify(txHash));
  await waitUntilBlockFinalized(provider, receipt.blockNumber, timeoutMs);
  const response = await getFinalizeWithdrawalParams(provider, receipt, index, timeoutMs);

  return {
    chainId,
    l2BatchNumber: response.l1BatchNumber,
    l2MessageIndex: response.l2MessageIndex,
    l2Sender: response.sender,
    l2TxNumberInBatch: response.l2TxNumberInBlock,
    message: response.message,
    merkleProof: response.proof,
  };
}

async function getInteropBundleData(
  provider: providers.JsonRpcProvider,
  receipt: ZkReceipt,
  index = 0,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  proofType?: string
): Promise<InteropBundleData> {
  const response = await getFinalizeWithdrawalParams(provider, receipt, index, timeoutMs, proofType);
  const message = normalizeHex(response.message);
  const bundlePayload = stripBundleIdentifier(message);
  const decodedRequest = abiCoder.decode([INTEROP_BUNDLE_ABI], bundlePayload);
  const decodedBundle = decodedRequest[0];

  const calls = [];
  for (let i = 0; i < decodedBundle[5].length; i++) {
    calls.push({
      version: decodedBundle[5][i][0],
      shadowAccount: decodedBundle[5][i][1],
      to: decodedBundle[5][i][2],
      from: decodedBundle[5][i][3],
      value: decodedBundle[5][i][4],
      data: decodedBundle[5][i][5],
    });
  }

  const xl2Input = {
    version: decodedBundle[0],
    sourceChainId: decodedBundle[1],
    destinationChainId: decodedBundle[2],
    destinationBaseTokenAssetId: decodedBundle[3],
    interopBundleSalt: decodedBundle[4],
    calls,
    bundleAttributes: {
      executionAddress: decodedBundle[6][0],
      unbundlerAddress: decodedBundle[6][1],
      useFixedFee: decodedBundle[6][2],
    },
  };

  const chainId = (await provider.getNetwork()).chainId;
  const rawData = abiCoder.encode([INTEROP_BUNDLE_ABI], [xl2Input]);
  const proofDecoded: MessageInclusionProof = {
    chainId,
    l1BatchNumber: response.l1BatchNumber,
    l2MessageIndex: response.l2MessageIndex,
    message: [response.l2TxNumberInBlock, response.sender, rawData],
    proof: response.proof,
  };

  return {
    rawData,
    l1BatchNumber: response.l1BatchNumber,
    gatewayBlockNumber: response.gatewayBlockNumber,
    proofDecoded,
  };
}

async function getFinalizeWithdrawalParams(
  provider: providers.JsonRpcProvider,
  receipt: ZkReceipt,
  index = 0,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  proofType?: string
): Promise<LiveFinalizeWithdrawalParams> {
  const { log, l2ToL1LogIndex, l2TxNumberInBlock } = getWithdrawalLogData(receipt, index);
  const proof = await getL2ToL1LogProof(provider, receipt.transactionHash, l2ToL1LogIndex, timeoutMs, proofType);

  const sender = ethers.utils.getAddress(ethers.utils.hexDataSlice(log.topics[1], 12));
  const message = abiCoder.decode(["bytes"], log.data)[0];

  return {
    l1BatchNumber: toNumber(proof.batchNumber),
    l2MessageIndex: toNumber(proof.id),
    l2TxNumberInBlock,
    gatewayBlockNumber: proof.gatewayBlockNumber === undefined ? undefined : toNumber(proof.gatewayBlockNumber),
    message,
    sender,
    proof: proof.proof,
  };
}

async function getZkReceipt(provider: providers.JsonRpcProvider, txHash: string): Promise<ZkReceipt> {
  const receipt = (await provider.send("eth_getTransactionReceipt", [txHash])) as RawZkReceipt | null;
  if (!receipt) {
    throw new Error(`Transaction ${txHash} is not mined`);
  }
  return {
    transactionHash: receipt.transactionHash ?? txHash,
    blockNumber: toNumber(receipt.blockNumber),
    logs: receipt.logs || [],
    l1BatchTxIndex: receipt.l1BatchTxIndex,
    l2ToL1Logs: receipt.l2ToL1Logs,
  };
}

function getWithdrawalLogData(
  receipt: ZkReceipt,
  index: number
): { log: ZkReceiptLog; l2ToL1LogIndex: number; l2TxNumberInBlock: number } {
  const l1MessageSentTopic = ethers.utils.id("L1MessageSent(address,bytes32,bytes)");
  const messageLogs = receipt.logs.filter(
    (log) =>
      log.address.toLowerCase() === L2_TO_L1_MESSENGER_ADDR.toLowerCase() &&
      log.topics[0].toLowerCase() === l1MessageSentTopic.toLowerCase()
  );
  const log = messageLogs[index];
  if (!log) {
    throw new Error(`L1MessageSent log ${index} not found in transaction ${receipt.transactionHash}`);
  }

  let seenMessengerLogs = 0;
  const l2ToL1LogIndex = (receipt.l2ToL1Logs || []).findIndex((l2ToL1Log) => {
    if (l2ToL1Log.sender.toLowerCase() !== L2_TO_L1_MESSENGER_ADDR.toLowerCase()) {
      return false;
    }
    if (seenMessengerLogs === index) {
      return true;
    }
    seenMessengerLogs++;
    return false;
  });

  if (l2ToL1LogIndex === -1) {
    throw new Error(`L2ToL1Log ${index} from messenger not found in transaction ${receipt.transactionHash}`);
  }

  const l2TxNumberInBlockValue = receipt.l2ToL1Logs?.[l2ToL1LogIndex]?.transactionIndex ?? receipt.l1BatchTxIndex;
  if (l2TxNumberInBlockValue === undefined) {
    throw new Error(`Transaction ${receipt.transactionHash} receipt does not include L2 tx number in batch`);
  }

  return { log, l2ToL1LogIndex, l2TxNumberInBlock: toNumber(l2TxNumberInBlockValue) };
}

async function getL2ToL1LogProof(
  provider: providers.JsonRpcProvider,
  txHash: string,
  l2ToL1LogIndex: number,
  timeoutMs: number,
  proofType?: string
): Promise<LogProof> {
  const start = Date.now();
  const params = !proofType || proofType === "default" ? [txHash, l2ToL1LogIndex] : [txHash, l2ToL1LogIndex, proofType];
  let proof: LogProof | null = null;
  let lastRetryableError: string | undefined;

  while (!proof) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `Log proof not found for ${txHash} at L2->L1 log index ${l2ToL1LogIndex}` +
          (lastRetryableError ? `. Last retryable RPC error: ${lastRetryableError}` : "")
      );
    }
    try {
      proof = (await provider.send("zks_getL2ToL1LogProof", params)) as LogProof | null;
    } catch (error) {
      if (!isRetryableLogProofError(error)) {
        throw error;
      }
      lastRetryableError = getRpcErrorMessage(error);
    }
    if (proof) {
      return proof;
    }
    await sleep(provider.pollingInterval);
  }

  return proof;
}

function isRetryableLogProofError(error: unknown): boolean {
  const message = getRpcErrorMessage(error).toLowerCase();
  return message.includes("proof not yet available") || message.includes("unstable_getbatchbyblocknumber");
}

function getRpcErrorMessage(error: unknown): string {
  const rpcError = error as {
    body?: string;
    error?: { message?: string };
    message?: string;
    reason?: string;
  };
  if (rpcError.error?.message) {
    return rpcError.error.message;
  }
  if (rpcError.reason) {
    return rpcError.reason;
  }
  if (rpcError.body) {
    try {
      const parsed = JSON.parse(rpcError.body) as { error?: { message?: string } };
      if (parsed.error?.message) {
        return parsed.error.message;
      }
    } catch {
      return rpcError.body;
    }
  }
  return rpcError.message || String(error);
}

async function waitUntilBlockFinalized(
  provider: providers.JsonRpcProvider,
  blockNumber: number,
  timeoutMs: number
): Promise<void> {
  const start = Date.now();
  let lastFinalizedBlock = 0;

  while (blockNumber > lastFinalizedBlock) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `waitUntilBlockFinalized: timed out after ${(timeoutMs / 1000).toFixed(
          0
        )}s waiting for block ${blockNumber} to be finalized (last finalized: ${lastFinalizedBlock})`
      );
    }

    const finalizedBlock = await provider.getBlock("finalized");
    lastFinalizedBlock = finalizedBlock?.number || 0;
    if (blockNumber > lastFinalizedBlock) {
      await sleep(provider.pollingInterval);
    }
  }
}

async function waitUntilBatchExecutedOnGateway(
  sourceChainId: number,
  batchNumber: number,
  timeoutMs: number
): Promise<void> {
  const start = Date.now();
  const gwProvider = getGatewayProvider();
  const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);
  const zkChainAddress = await bridgehub.getZKChain(sourceChainId);
  const getters = new Contract(zkChainAddress, getAbi("IZKChain"), gwProvider);
  let currentExecutedBatchNumber = 0;

  while (currentExecutedBatchNumber < batchNumber) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `waitUntilBatchExecutedOnGateway: timed out after ${(timeoutMs / 1000).toFixed(
          0
        )}s waiting for source chain ${sourceChainId} batch ${batchNumber} (current executed: ${currentExecutedBatchNumber})`
      );
    }

    currentExecutedBatchNumber = toNumber(await getters.getTotalBatchesExecuted());
    if (currentExecutedBatchNumber < batchNumber) {
      await sleep(gwProvider.pollingInterval);
    }
  }
}

async function waitForInteropRootNonZero(
  destProvider: providers.JsonRpcProvider,
  gwBlockNumber: number,
  timeoutMs: number
): Promise<void> {
  const start = Date.now();
  const gwChainId = (await getGatewayProvider().getNetwork()).chainId;
  const interopRootStorage = new Contract(L2_INTEROP_ROOT_STORAGE_ADDR, getAbi("L2InteropRootStorage"), destProvider);
  let currentRoot = ethers.constants.HashZero;

  while (currentRoot === ethers.constants.HashZero) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(
        `waitForInteropRootNonZero: timed out after ${(timeoutMs / 1000).toFixed(
          0
        )}s waiting for gateway block ${gwBlockNumber} root on destination chain`
      );
    }

    currentRoot = await interopRootStorage.interopRoots(gwChainId, gwBlockNumber);
    if (currentRoot === ethers.constants.HashZero) {
      await sleep(destProvider.pollingInterval);
    }
  }
}

function getGWBlockNumber(proof: string[]): number {
  const settlementLayerProof = getSettlementLayerProofData(proof);
  if (!settlementLayerProof) {
    throw new Error("Proof does not contain settlement-layer batch data");
  }
  return settlementLayerProof.batchNumber;
}

function getSettlementLayerProofData(proof: string[]): { chainId: number; batchNumber: number } | undefined {
  if (proof.length === 0) {
    throw new Error("Cannot parse empty proof");
  }

  const metadata = normalizeHex(proof[0]);
  const isMetadataProof =
    metadata.length === PROOF_METADATA_HEX_LENGTH &&
    metadata.slice(PROOF_METADATA_PREFIX_HEX_LENGTH) === "0".repeat(PROOF_METADATA_TRAILING_ZERO_HEX_LENGTH);
  if (!isMetadataProof) {
    return undefined;
  }

  const metadataVersion = parseInt(metadata.slice(2, 4), 16);
  if (metadataVersion !== PROOF_METADATA_VERSION) {
    throw new Error(`Unsupported proof metadata version ${metadataVersion}`);
  }

  const logLeafProofLen = parseInt(metadata.slice(4, 6), 16);
  const batchLeafProofLen = parseInt(metadata.slice(6, 8), 16);
  const finalProofNode = parseInt(metadata.slice(8, 10), 16) !== 0;
  if (finalProofNode) {
    return undefined;
  }

  const packedBatchInfoIndex = 1 + logLeafProofLen + 1 + batchLeafProofLen;
  const settlementLayerChainIdIndex = packedBatchInfoIndex + 1;
  if (proof.length <= settlementLayerChainIdIndex) {
    throw new Error("Proof metadata points outside the proof array");
  }

  const packedBatchInfo = normalizeHex(proof[packedBatchInfoIndex]);
  const batchNumber = ethers.BigNumber.from(`0x${packedBatchInfo.slice(2, 34)}`).toNumber();
  const chainId = ethers.BigNumber.from(proof[settlementLayerChainIdIndex]).toNumber();

  return { chainId, batchNumber };
}

function stripBundleIdentifier(message: string): string {
  const normalized = normalizeHex(message);
  const bytesToStrip = Number(process.env.LIVE_INTEROP_BUNDLE_IDENTIFIER_BYTES || "1");
  return ethers.utils.hexDataSlice(normalized, bytesToStrip);
}

function getGatewayProvider(): providers.JsonRpcProvider {
  const gwRpcUrl = process.env.LIVE_GW_RPC?.trim();
  if (!gwRpcUrl) {
    throw new Error("LIVE_GW_RPC is required when ANVIL_INTEROP_LIVE=1");
  }
  return new ethers.providers.JsonRpcProvider(gwRpcUrl);
}

function normalizeHex(value: string): string {
  return value.startsWith("0x") ? value : `0x${value}`;
}

function toNumber(value: unknown): number {
  return ethers.BigNumber.from(value || 0).toNumber();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
