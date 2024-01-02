import type { BigNumberish, BytesLike } from "ethers";
import { BigNumber, ethers } from "ethers";
import type { Address } from "zksync-web3/build/src/types";

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const IERC20_INTERFACE = require("@openzeppelin/contracts/build/contracts/IERC20");
export const DEFAULT_REVERT_REASON = "VM did not revert";

export const EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
export const DEFAULT_L2_LOGS_TREE_ROOT_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
export const L2_SYSTEM_CONTEXT_ADDRESS = "0x000000000000000000000000000000000000800b";
export const L2_BOOTLOADER_ADDRESS = "0x0000000000000000000000000000000000008001";
export const L2_KNOWN_CODE_STORAGE_ADDRESS = "0x0000000000000000000000000000000000008004";
export const L2_TO_L1_MESSENGER = "0x0000000000000000000000000000000000008008";
export const L2_BYTECODE_COMPRESSOR_ADDRESS = "0x000000000000000000000000000000000000800e";

export enum SYSTEM_LOG_KEYS {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  TOTAL_L2_TO_L1_PUBDATA_KEY,
  STATE_DIFF_HASH_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  PREV_BATCH_HASH_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
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
      revertReason = e.reason.match(/reverted with reason string '(.*)'/)?.[1] || e.reason;
    } catch (_) {
      throw e;
    }
  }
  return revertReason;
}

export async function requestExecute(
  mailbox: ethers.Contract,
  to: Address,
  l2Value: ethers.BigNumber,
  calldata: ethers.BytesLike,
  l2GasLimit: ethers.BigNumber,
  factoryDeps: BytesLike[],
  refundRecipient: string,
  overrides?: ethers.PayableOverrides
) {
  overrides ??= {};
  overrides.gasPrice ??= mailbox.provider.getGasPrice();

  if (!overrides.value) {
    const baseCost = await mailbox.l2TransactionBaseCost(
      overrides.gasPrice,
      l2GasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    overrides.value = baseCost.add(l2Value);
  }

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

export function createSystemLogs() {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.TOTAL_L2_TO_L1_PUBDATA_KEY,
      "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563"
    ),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.STATE_DIFF_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(true, L2_SYSTEM_CONTEXT_ADDRESS, SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(true, L2_BOOTLOADER_ADDRESS, SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY, EMPTY_STRING_KECCAK),
    constructL2Log(true, L2_BOOTLOADER_ADDRESS, SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY, ethers.constants.HashZero),
  ];
}

export function genesisStoredBatchInfo(): StoredBatchInfo {
  return {
    batchNumber: 0,
    batchHash: ethers.constants.HashZero,
    indexRepeatedStorageChanges: 0,
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    timestamp: 0,
    commitment: ethers.constants.HashZero,
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
  totalL2ToL1Pubdata: BytesLike;
}
