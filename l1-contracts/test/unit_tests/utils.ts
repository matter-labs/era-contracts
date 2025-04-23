import * as hardhat from "hardhat";
import type { BigNumberish, BytesLike } from "ethers";
import { BigNumber, ethers } from "ethers";
import type { Address } from "zksync-ethers/build/types";

import type { IBridgehub } from "../../typechain/IBridgehub";
import type { IL1ERC20Bridge } from "../../typechain/IL1ERC20Bridge";
import type { IMailbox } from "../../typechain/IMailbox";

import type { ExecutorFacet } from "../../typechain";

import type { FeeParams, L2CanonicalTransaction } from "../../src.ts/utils";
import {
  ADDRESS_ONE,
  PubdataPricingMode,
  EMPTY_STRING_KECCAK,
  STORED_BATCH_INFO_ABI_STRING,
  COMMIT_BATCH_INFO_ABI_STRING,
  PRIORITY_OPS_BATCH_INFO_ABI_STRING,
} from "../../src.ts/utils";
import { packSemver } from "../../scripts/utils";
import { keccak256, hexConcat, defaultAbiCoder } from "ethers/lib/utils";

export const CONTRACTS_GENESIS_PROTOCOL_VERSION = packSemver(0, 21, 0).toString();
// eslint-disable-next-line @typescript-eslint/no-var-requires
export const IERC20_INTERFACE = require("@openzeppelin/contracts-v4/build/contracts/IERC20");
export const DEFAULT_REVERT_REASON = "VM did not revert";

export const DEFAULT_L2_LOGS_TREE_ROOT_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
export const DUMMY_MERKLE_PROOF_START = "0x0101000000000000000000000000000000000000000000000000000000000000";
export const DUMMY_MERKLE_PROOF_2_START = "0x0109000000000000000000000000000000000000000000000000000000000000";
export const L2_SYSTEM_CONTEXT_ADDRESS = "0x000000000000000000000000000000000000800b";
export const L2_BOOTLOADER_ADDRESS = "0x0000000000000000000000000000000000008001";
export const L2_KNOWN_CODE_STORAGE_ADDRESS = "0x0000000000000000000000000000000000008004";
export const L2_TO_L1_MESSENGER = "0x0000000000000000000000000000000000008008";
export const L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = "0x000000000000000000000000000000000000800a";
export const L2_BYTECODE_COMPRESSOR_ADDRESS = "0x000000000000000000000000000000000000800e";
export const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
export const PUBDATA_CHUNK_PUBLISHER_ADDRESS = "0x0000000000000000000000000000000000008011";

export const SYSTEM_UPGRADE_TX_TYPE = 254;

export function randomAddress() {
  return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}

export enum SYSTEM_LOG_KEYS {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
  // Note, that it is important that `PREV_BATCH_HASH_KEY` has position
  // `4` since it is the same as it was in the previous protocol version and
  // it is the only one that is emitted before the system contracts are upgraded.
  PREV_BATCH_HASH_KEY,
  L2_DA_VALIDATOR_OUTPUT_HASH_KEY,
  USED_L2_DA_VALIDATOR_ADDRESS_KEY,
  EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
}

// The default price for the pubdata in L2 gas to be used in L1->L2 transactions
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA =
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

/// Set of parameters that are needed to test the processing of priority operations
export class DummyOp {
  constructor(
    public id: number,
    public expirationBatch: BigNumber,
    public layer2Tip: number
  ) {}
}

export async function getCallRevertReason(promise) {
  let revertReason = DEFAULT_REVERT_REASON;
  try {
    await promise;
  } catch (e) {
    try {
      await promise;
    } catch (e) {
      // kl to do. The error messages are messed up. So we need all these cases.
      try {
        revertReason = e.reason.match(/reverted with reason string '([^']*)'/)?.[1] || e.reason;
        if (
          revertReason === "cannot estimate gas; transaction may fail or may require manual gas limit" ||
          revertReason === DEFAULT_REVERT_REASON
        ) {
          revertReason = e.error.toString().match(/revert with reason "([^']*)"/)[1] || "PLACEHOLDER_STRING";
        }
      } catch (_) {
        try {
          if (
            revertReason === "cannot estimate gas; transaction may fail or may require manual gas limit" ||
            revertReason === DEFAULT_REVERT_REASON
          ) {
            if (e.error) {
              revertReason =
                e.error.toString().match(/reverted with reason string '([^']*)'/)[1] || "PLACEHOLDER_STRING";
            } else {
              revertReason = e.toString().match(/reverted with reason string '([^']*)'/)[1] || "PLACEHOLDER_STRING";
            }
          }
        } catch (_) {
          try {
            if (
              revertReason === "cannot estimate gas; transaction may fail or may require manual gas limit" ||
              revertReason === DEFAULT_REVERT_REASON
            ) {
              if (e.error) {
                revertReason =
                  e.error.toString().match(/reverted with custom error '([^']*)'/)[1] || "PLACEHOLDER_STRING";
              } else {
                revertReason = e.toString().match(/reverted with custom error '([^']*)'/)[1] || "PLACEHOLDER_STRING";
              }
            }
          } catch (_) {
            throw e;
          }
        }
      }
    }
  }
  return revertReason;
}

export async function requestExecute(
  chainId: ethers.BigNumberish,
  bridgehub: IBridgehub,
  to: Address,
  l2Value: ethers.BigNumber,
  calldata: ethers.BytesLike,
  l2GasLimit: ethers.BigNumber,
  factoryDeps: BytesLike[],
  refundRecipient: string,
  overrides?: ethers.PayableOverrides
) {
  overrides ??= {};
  overrides.gasPrice ??= bridgehub.provider.getGasPrice();
  // overrides.gasLimit ??= 30000000;
  if (!overrides.value) {
    const baseCost = await bridgehub.l2TransactionBaseCost(
      chainId,
      await overrides.gasPrice,
      l2GasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    overrides.value = baseCost.add(l2Value);
  }

  return await bridgehub.requestL2TransactionDirect(
    {
      chainId,
      l2Contract: to,
      mintValue: await overrides.value,
      l2Value,
      l2Calldata: calldata,
      l2GasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps,
      refundRecipient,
    },
    overrides
  );
}

// due to gas reasons we call the chains' contract directly, instead of the bridgehub.
export async function requestExecuteDirect(
  mailbox: IMailbox,
  to: Address,
  l2Value: ethers.BigNumber,
  calldata: ethers.BytesLike,
  l2GasLimit: ethers.BigNumber,
  factoryDeps: BytesLike[],
  refundRecipient: string,
  value?: ethers.BigNumber
) {
  const gasPrice = await mailbox.provider.getGasPrice();

  // we call bridgehubChain direcetly to avoid running out of gas.
  const baseCost = await mailbox.l2TransactionBaseCost(
    gasPrice,
    ethers.BigNumber.from(100000),
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const overrides = {
    gasPrice,
    value: baseCost.add(value || ethers.BigNumber.from(0)),
  };

  return await mailbox.requestL2Transaction(
    to,
    l2Value,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    refundRecipient,
    overrides
  );
}

export function constructL2Log(isService: boolean, sender: string, key: number | string, value: string) {
  return ethers.utils.hexConcat([
    isService ? "0x0001" : "0x0000",
    "0x0000",
    sender,
    ethers.utils.hexZeroPad(ethers.utils.hexlify(key), 32),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(value), 32),
  ]);
}

export function createSystemLogs(
  chainedPriorityTxHashKey?: BytesLike,
  numberOfLayer1Txs?: BigNumberish,
  previousBatchHash?: BytesLike,
  l2DaValidatorOutputHash?: BytesLike
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
      chainedPriorityTxHashKey ? chainedPriorityTxHashKey.toString() : EMPTY_STRING_KECCAK
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
      numberOfLayer1Txs ? numberOfLayer1Txs.toString() : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      previousBatchHash ? ethers.utils.hexlify(previousBatchHash) : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.L2_DA_VALIDATOR_OUTPUT_HASH_KEY,
      l2DaValidatorOutputHash ? ethers.utils.hexlify(l2DaValidatorOutputHash) : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.USED_L2_DA_VALIDATOR_ADDRESS_KEY,
      process.env.CONTRACTS_L2_DA_VALIDATOR_ADDR
    ),
  ];
}

export function createSystemLogsWithUpgrade(
  chainedPriorityTxHashKey?: BytesLike,
  numberOfLayer1Txs?: BigNumberish,
  upgradeTxHash?: string,
  previousBatchHash?: string,
  l2DaValidatorOutputHash?: BytesLike
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      previousBatchHash ? previousBatchHash : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
      chainedPriorityTxHashKey ? chainedPriorityTxHashKey.toString() : EMPTY_STRING_KECCAK
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
      numberOfLayer1Txs ? numberOfLayer1Txs.toString() : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.L2_DA_VALIDATOR_OUTPUT_HASH_KEY,
      ethers.utils.hexlify(l2DaValidatorOutputHash) || ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.USED_L2_DA_VALIDATOR_ADDRESS_KEY,
      process.env.CONTRACTS_L2_DA_VALIDATOR_ADDR || ethers.constants.AddressZero
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
      upgradeTxHash
    ),
  ];
}

export function genesisStoredBatchInfo(): StoredBatchInfo {
  return {
    batchNumber: 0,
    batchHash: "0x0000000000000000000000000000000000000000000000000000000000000001",
    indexRepeatedStorageChanges: 1,
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    timestamp: 0,
    commitment: "0x0000000000000000000000000000000000000000000000000000000000000001",
  };
}

// Packs the batch timestamp and L2 block timestamp and returns the 32-byte hex string
// which should be used for the "key" field of the L2->L1 system context log.
export function packBatchTimestampAndBatchTimestamp(
  batchTimestamp: BigNumberish,
  l2BlockTimestamp: BigNumberish
): string {
  const packedNum = BigNumber.from(batchTimestamp).shl(128).or(BigNumber.from(l2BlockTimestamp));
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(packedNum), 32);
}

export function defaultFeeParams(): FeeParams {
  return {
    pubdataPricingMode: PubdataPricingMode.Rollup,
    batchOverheadL1Gas: 1_000_000,
    maxPubdataPerBatch: 110_000,
    maxL2GasPerBatch: 80_000_000,
    priorityTxMaxPubdata: 99_000,
    minimalL2GasPrice: 250_000_000, // 0.25 gwei
  };
}

export interface StoredBatchInfo {
  batchNumber: BigNumberish;
  batchHash: BytesLike;
  indexRepeatedStorageChanges: BigNumberish;
  numberOfLayer1Txs: BigNumberish;
  priorityOperationsHash: BytesLike;
  l2LogsTreeRoot: BytesLike;
  timestamp: BigNumberish;
  commitment: BytesLike;
}

export interface CommitBatchInfo {
  batchNumber: BigNumberish;
  timestamp: number;
  indexRepeatedStorageChanges: BigNumberish;
  newStateRoot: BytesLike;
  numberOfLayer1Txs: BigNumberish;
  priorityOperationsHash: BytesLike;
  bootloaderHeapInitialContentsHash: BytesLike;
  eventsQueueStateHash: BytesLike;
  systemLogs: BytesLike;
  operatorDAInput: BytesLike;
}

export interface PriorityOpsBatchInfo {
  leftPath: Array<BytesLike>;
  rightPath: Array<BytesLike>;
  itemHashes: Array<BytesLike>;
}

export async function depositERC20(
  bridge: IL1ERC20Bridge,
  bridgehubContract: IBridgehub,
  chainId: string,
  l1ChainId: number,
  l2Receiver: string,
  l1Token: string,
  amount: ethers.BigNumber,
  l2GasLimit: number,
  l2RefundRecipient = ethers.constants.AddressZero
) {
  const gasPrice = await bridge.provider.getGasPrice();
  const gasPerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
  const neededValue = await bridgehubContract.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata);
  const ethIsBaseToken = (await bridgehubContract.baseToken(chainId)) == ADDRESS_ONE;

  const deposit = await bridge["deposit(address,address,uint256,uint256,uint256,address)"](
    l2Receiver,
    l1Token,
    amount,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    l2RefundRecipient,
    {
      value: ethIsBaseToken ? neededValue : 0,
    }
  );
  await deposit.wait();
}

export function buildL2CanonicalTransaction(tx: Partial<L2CanonicalTransaction>): L2CanonicalTransaction {
  return {
    txType: SYSTEM_UPGRADE_TX_TYPE,
    from: ethers.constants.AddressZero,
    to: ethers.constants.AddressZero,
    gasLimit: 5000000,
    gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    maxFeePerGas: 0,
    maxPriorityFeePerGas: 0,
    paymaster: 0,
    nonce: 0,
    value: 0,
    reserved: [0, 0, 0, 0],
    data: "0x",
    signature: "0x",
    factoryDeps: [],
    paymasterInput: "0x",
    reservedDynamic: "0x",
    ...tx,
  };
}

export type CommitBatchInfoWithTimestamp = Partial<CommitBatchInfo> & {
  batchNumber: BigNumberish;
};

function padStringWithZeroes(str: string, lenBytes: number): string {
  const strLen = lenBytes * 2;
  if (str.length > strLen) {
    throw new Error("String is too long");
  }
  const paddingLength = strLen - str.length;
  return str + "0".repeat(paddingLength);
}

// Returns a pair of strings:
// - the expected pubdata commitemnt
// - the required rollup l2 da hash output
export function buildL2DARollupPubdataCommitment(stateDiffHash: string, fullPubdata: string): [string, string] {
  const BLOB_SIZE_BYTES = 126_976;
  const fullPubdataHash = ethers.utils.keccak256(fullPubdata);
  if (ethers.utils.arrayify(fullPubdata).length > BLOB_SIZE_BYTES) {
    throw new Error("Too much pubdata");
  }
  const blobsProvided = 1;

  const blobLinearHash = keccak256(padStringWithZeroes(fullPubdata, BLOB_SIZE_BYTES));

  const l1DAOutput = ethers.utils.hexConcat([
    stateDiffHash,
    fullPubdataHash,
    ethers.utils.hexlify(blobsProvided),
    blobLinearHash,
  ]);
  const l1DAOutputHash = ethers.utils.keccak256(l1DAOutput);

  // After the header the 00 byte is for "calldata" mode.
  // Then, there is the full pubdata.
  // Then, there are 32 bytes for blob commitment. They must have at least one non-zero byte,
  // so it will be the last one.
  const fullPubdataCommitment = `${l1DAOutput}00${fullPubdata.slice(2)}${"0".repeat(62)}01`;

  return [fullPubdataCommitment, l1DAOutputHash];
}

export async function buildCommitBatchInfoWithUpgrade(
  prevInfo: StoredBatchInfo,
  info: CommitBatchInfoWithTimestamp,
  upgradeTxHash: string
): Promise<CommitBatchInfo> {
  const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock("latest")).timestamp;

  const [fullPubdataCommitment, l1DAOutputHash] = buildL2DARollupPubdataCommitment(ethers.constants.HashZero, "0x");

  const systemLogs = createSystemLogsWithUpgrade(
    info.priorityOperationsHash,
    info.numberOfLayer1Txs,
    upgradeTxHash,
    ethers.utils.hexlify(prevInfo.batchHash),
    l1DAOutputHash
  );
  systemLogs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
    true,
    L2_SYSTEM_CONTEXT_ADDRESS,
    SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
    packBatchTimestampAndBatchTimestamp(timestamp, timestamp)
  );

  return {
    timestamp,
    indexRepeatedStorageChanges: 1,
    newStateRoot: ethers.utils.randomBytes(32),
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    systemLogs: ethers.utils.hexConcat(systemLogs),
    operatorDAInput: fullPubdataCommitment,
    bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
    eventsQueueStateHash: ethers.utils.randomBytes(32),
    ...info,
  };
}

export async function makeExecutedEqualCommitted(
  proxyExecutor: ExecutorFacet,
  prevBatchInfo: StoredBatchInfo,
  batchesToProve: StoredBatchInfo[],
  batchesToExecute: StoredBatchInfo[]
) {
  batchesToExecute = [...batchesToProve, ...batchesToExecute];

  await (
    await proxyExecutor.proveBatchesSharedBridge(0, ...encodeProveBatchesData(prevBatchInfo, batchesToProve, []))
  ).wait();

  const dummyMerkleProofs = batchesToExecute.map(() => ({ leftPath: [], rightPath: [], itemHashes: [] }));
  await (
    await proxyExecutor.executeBatchesSharedBridge(0, ...encodeExecuteBatchesData(batchesToExecute, dummyMerkleProofs))
  ).wait();
}

export function getBatchStoredInfo(commitInfo: CommitBatchInfo, commitment: string): StoredBatchInfo {
  return {
    batchNumber: commitInfo.batchNumber,
    batchHash: commitInfo.newStateRoot,
    indexRepeatedStorageChanges: commitInfo.indexRepeatedStorageChanges,
    numberOfLayer1Txs: commitInfo.numberOfLayer1Txs,
    priorityOperationsHash: commitInfo.priorityOperationsHash,
    l2LogsTreeRoot: ethers.constants.HashZero,
    timestamp: commitInfo.timestamp,
    commitment: commitment,
  };
}

export function encodeCommitBatchesData(
  storedBatchInfo: StoredBatchInfo,
  commitBatchInfos: Array<CommitBatchInfo>
): [BigNumberish, BigNumberish, string] {
  const encodedCommitDataWithoutVersion = defaultAbiCoder.encode(
    [STORED_BATCH_INFO_ABI_STRING, `${COMMIT_BATCH_INFO_ABI_STRING}[]`],
    [storedBatchInfo, commitBatchInfos]
  );
  const commitData = hexConcat(["0x00", encodedCommitDataWithoutVersion]);
  return [commitBatchInfos[0].batchNumber, commitBatchInfos[commitBatchInfos.length - 1].batchNumber, commitData];
}

export function encodeProveBatchesData(
  prevBatch: StoredBatchInfo,
  committedBatches: Array<StoredBatchInfo>,
  proof: Array<BigNumberish>
): [BigNumberish, BigNumberish, string] {
  const encodedProveDataWithoutVersion = defaultAbiCoder.encode(
    [STORED_BATCH_INFO_ABI_STRING, `${STORED_BATCH_INFO_ABI_STRING}[]`, "uint256[]"],
    [prevBatch, committedBatches, proof]
  );
  const proveData = hexConcat(["0x00", encodedProveDataWithoutVersion]);
  return [committedBatches[0].batchNumber, committedBatches[committedBatches.length - 1].batchNumber, proveData];
}

export function encodeExecuteBatchesData(
  batchesData: Array<StoredBatchInfo>,
  priorityOpsBatchInfo: Array<PriorityOpsBatchInfo>
): [BigNumberish, BigNumberish, string] {
  const encodedExecuteDataWithoutVersion = defaultAbiCoder.encode(
    [`${STORED_BATCH_INFO_ABI_STRING}[]`, `${PRIORITY_OPS_BATCH_INFO_ABI_STRING}[]`],
    [batchesData, priorityOpsBatchInfo]
  );
  const executeData = hexConcat(["0x00", encodedExecuteDataWithoutVersion]);
  return [batchesData[0].batchNumber, batchesData[batchesData.length - 1].batchNumber, executeData];
}
