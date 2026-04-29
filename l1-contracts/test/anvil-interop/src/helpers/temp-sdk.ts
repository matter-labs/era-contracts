import type { BytesLike, providers } from "ethers";
import { Contract, ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { L2_BRIDGEHUB_ADDR, L2_INTEROP_ROOT_STORAGE_ADDR, L2_TO_L1_MESSENGER_ADDR } from "../core/const";

const INTEROP_BUNDLE_ABI =
  "tuple(bytes1 version, uint256 sourceChainId, uint256 destinationChainId, bytes32 destinationBaseTokenAssetId, bytes32 interopBundleSalt, tuple(bytes1 version, bool shadowAccount, address to, address from, uint256 value, bytes data)[] calls, (bytes executionAddress, bytes unbundlerAddress, bool useFixedFee) bundleAttributes)";

const DEFAULT_LIVE_INTEROP_PROOF_TYPE = "messageRoot";
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const abiCoder = ethers.utils.defaultAbiCoder;

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

interface FinalizeWithdrawalParams {
  l1BatchNumber: number;
  l2MessageIndex: number;
  l2TxNumberInBlock: number;
  gatewayBlockNumber?: number;
  message: string;
  sender: string;
  proof: string[];
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

  const bundleData = await getInteropBundleData(sourceProvider, receipt, index, timeoutMs);
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

async function getInteropBundleData(
  provider: providers.JsonRpcProvider,
  receipt: ZkReceipt,
  index = 0,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<InteropBundleData> {
  const response = await getFinalizeWithdrawalParams(provider, receipt, index, timeoutMs);
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
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<FinalizeWithdrawalParams> {
  const { log, l2ToL1LogIndex, l2TxNumberInBlock } = getWithdrawalLogData(receipt, index);
  const proof = await getL2ToL1LogProof(provider, receipt.transactionHash, l2ToL1LogIndex, timeoutMs);

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
  timeoutMs: number
): Promise<LogProof> {
  const start = Date.now();
  const proofType = process.env.LIVE_INTEROP_PROOF_TYPE?.trim() || DEFAULT_LIVE_INTEROP_PROOF_TYPE;
  const params = proofType === "default" ? [txHash, l2ToL1LogIndex] : [txHash, l2ToL1LogIndex, proofType];
  let proof: LogProof | null = null;

  while (!proof) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(`Log proof not found for ${txHash} at L2->L1 log index ${l2ToL1LogIndex}`);
    }
    proof = (await provider.send("zks_getL2ToL1LogProof", params)) as LogProof | null;
    if (proof) {
      return proof;
    }
    await sleep(provider.pollingInterval);
  }

  return proof;
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
  const gwProofIndex = 1 + parseInt(proof[0].slice(4, 6), 16) + 1 + parseInt(proof[0].slice(6, 8), 16);
  return parseInt(proof[gwProofIndex].slice(2, 34), 16);
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
