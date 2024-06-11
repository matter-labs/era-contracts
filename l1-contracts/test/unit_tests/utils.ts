import * as hardhat from "hardhat";
import type { BigNumberish, BytesLike } from "ethers";
import { BigNumber, ethers } from "ethers";
import type { Address } from "zksync-ethers/build/types";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-ethers/build/utils";

import type { IBridgehub } from "../../typechain/IBridgehub";
import type { IL1ERC20Bridge } from "../../typechain/IL1ERC20Bridge";
import type { IMailbox } from "../../typechain/IMailbox";

import type { ExecutorFacet } from "../../typechain";

import type { FeeParams, L2CanonicalTransaction } from "../../src.ts/utils";
import { ADDRESS_ONE, PubdataPricingMode, EMPTY_STRING_KECCAK } from "../../src.ts/utils";
import { packSemver } from "../../scripts/utils";

export const CONTRACTS_GENESIS_PROTOCOL_VERSION = packSemver(0, 21, 0).toString();
// eslint-disable-next-line @typescript-eslint/no-var-requires
export const IERC20_INTERFACE = require("@openzeppelin/contracts/build/contracts/IERC20");
export const DEFAULT_REVERT_REASON = "VM did not revert";

export const DEFAULT_L2_LOGS_TREE_ROOT_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
export const L2_SYSTEM_CONTEXT_ADDRESS = "0x000000000000000000000000000000000000800b";
export const L2_BOOTLOADER_ADDRESS = "0x0000000000000000000000000000000000008001";
export const L2_KNOWN_CODE_STORAGE_ADDRESS = "0x0000000000000000000000000000000000008004";
export const L2_TO_L1_MESSENGER = "0x0000000000000000000000000000000000008008";
export const L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = "0x000000000000000000000000000000000000800a";
export const L2_BYTECODE_COMPRESSOR_ADDRESS = "0x000000000000000000000000000000000000800e";
export const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
export const PUBDATA_CHUNK_PUBLISHER_ADDRESS = "0x0000000000000000000000000000000000008011";
const PUBDATA_HASH = "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563";

export const SYSTEM_UPGRADE_TX_TYPE = 254;

export function randomAddress() {
  return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}

export enum SYSTEM_LOG_KEYS {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  TOTAL_L2_TO_L1_PUBDATA_KEY,
  STATE_DIFF_HASH_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  PREV_BATCH_HASH_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
  BLOB_ONE_HASH_KEY,
  BLOB_TWO_HASH_KEY,
  BLOB_THREE_HASH_KEY,
  BLOB_FOUR_HASH_KEY,
  BLOB_FIVE_HASH_KEY,
  BLOB_SIX_HASH_KEY,
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
          throw e;
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
  previousBatchHash?: BytesLike
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.TOTAL_L2_TO_L1_PUBDATA_KEY, PUBDATA_HASH),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.STATE_DIFF_HASH_KEY, ethers.constants.HashZero),
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
      previousBatchHash ? ethers.utils.hexlify(previousBatchHash) : ethers.constants.HashZero
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
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_ONE_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_TWO_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_THREE_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_FOUR_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_FIVE_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_SIX_HASH_KEY, ethers.constants.HashZero),
  ];
}

export function createSystemLogsWithUpgrade(
  chainedPriorityTxHashKey?: BytesLike,
  numberOfLayer1Txs?: BigNumberish,
  upgradeTxHash?: string,
  previousBatchHash?: string
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.TOTAL_L2_TO_L1_PUBDATA_KEY, PUBDATA_HASH),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.STATE_DIFF_HASH_KEY, ethers.constants.HashZero),
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
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_ONE_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_TWO_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_THREE_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_FOUR_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      PUBDATA_CHUNK_PUBLISHER_ADDRESS,
      SYSTEM_LOG_KEYS.BLOB_FIVE_HASH_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(true, PUBDATA_CHUNK_PUBLISHER_ADDRESS, SYSTEM_LOG_KEYS.BLOB_SIX_HASH_KEY, ethers.constants.HashZero),
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
  pubdataCommitments: BytesLike;
}

export async function depositERC20(
  bridge: IL1ERC20Bridge,
  bridgehubContract: IBridgehub,
  chainId: string,
  l2Receiver: string,
  l1Token: string,
  amount: ethers.BigNumber,
  l2GasLimit: number,
  l2RefundRecipient = ethers.constants.AddressZero
) {
  const gasPrice = await bridge.provider.getGasPrice();
  const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
  const neededValue = await bridgehubContract.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata);
  const ethIsBaseToken = (await bridgehubContract.baseToken(chainId)) == ADDRESS_ONE;

  const deposit = await bridge["deposit(address,address,uint256,uint256,uint256,address)"](
    l2Receiver,
    l1Token,
    amount,
    l2GasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
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
    gasPerPubdataByteLimit: REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
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

export async function buildCommitBatchInfoWithUpgrade(
  prevInfo: StoredBatchInfo,
  info: CommitBatchInfoWithTimestamp,
  upgradeTxHash: string
): Promise<CommitBatchInfo> {
  const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock("latest")).timestamp;
  const systemLogs = createSystemLogsWithUpgrade(
    info.priorityOperationsHash,
    info.numberOfLayer1Txs,
    upgradeTxHash,
    ethers.utils.hexlify(prevInfo.batchHash)
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
    pubdataCommitments: `0x${"0".repeat(130)}`,
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
    await proxyExecutor.proveBatches(prevBatchInfo, batchesToProve, {
      recursiveAggregationInput: [],
      serializedProof: [],
    })
  ).wait();

  await (await proxyExecutor.executeBatches(batchesToExecute)).wait();
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
