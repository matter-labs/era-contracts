import { BigNumber, BigNumberish, BytesLike, ethers } from 'ethers';
import { Address } from 'zksync-web3/build/src/types';

export const IERC20_INTERFACE = require('@openzeppelin/contracts/build/contracts/IERC20');
export const DEFAULT_REVERT_REASON = 'VM did not revert';

export const EMPTY_STRING_KECCAK = `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`;
export const DEFAULT_L2_LOGS_TREE_ROOT_HASH = `0x0000000000000000000000000000000000000000000000000000000000000000`;
export const L2_SYSTEM_CONTEXT_ADDRESS = `0x000000000000000000000000000000000000800b`;
export const L2_BOOTLOADER_ADDRESS = `0x0000000000000000000000000000000000008001`;
export const L2_KNOWN_CODE_STORAGE_ADDRESS = `0x0000000000000000000000000000000000008004`;
export const L2_TO_L1_MESSENGER = `0x0000000000000000000000000000000000008008`;

// The default price for the pubdata in L2 gas to be used in L1->L2 transactions
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA =
    require('../../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

/// Set of parameters that are needed to test the processing of priority operations
export class DummyOp {
    constructor(public id: number, public expirationBlock: BigNumber, public layer2Tip: number) {}
}

export enum AccessMode {
    Closed = 0,
    SpecialAccessOnly = 1,
    Public = 2
}

export async function getCallRevertReason(promise) {
    let revertReason = DEFAULT_REVERT_REASON;
    try {
        await promise;
    } catch (e) {
        // KL todo. The error messages are messed up. So we need all these cases.
        try {
            revertReason = e.reason.match(/reverted with reason string '([^']*)'/)?.[1] || e.reason;
            if (
                revertReason === 'cannot estimate gas; transaction may fail or may require manual gas limit' ||
                revertReason === DEFAULT_REVERT_REASON
            ) {
                revertReason = e.error.toString().match(/revert with reason \"([^']*)\"/)[1] || 'PLACEHOLDER_STRING';
            }
        } catch (_) {
            try {
                if (
                    revertReason === 'cannot estimate gas; transaction may fail or may require manual gas limit' ||
                    revertReason === DEFAULT_REVERT_REASON
                ) {
                    if (e.error) {
                        revertReason =
                            e.error.toString().match(/reverted with reason string '([^']*)'/)[1] || 'PLACEHOLDER_STRING';
                    } else {
                        revertReason =
                            e.toString().match(/reverted with reason string '([^']*)'/)[1] || 'PLACEHOLDER_STRING';
                    }
                }
            } catch (_) {
                throw e.error.toString().slice(0, 5000) + e.error.toString().slice(-6000);
            }
        }
    }
    return revertReason;
}

export async function requestExecute(
    chainId: ethers.BigNumberish,
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
            chainId,
            overrides.gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        overrides.value = baseCost.add(l2Value);
    }

    return await mailbox.requestL2Transaction(
        chainId,
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

// due to gas reasons we call tha Chais's contract directly, instead of the bridgehead.
export async function requestExecuteDirect(
    mailbox: ethers.Contract,
    to: Address,
    l2Value: ethers.BigNumber,
    calldata: ethers.BytesLike,
    l2GasLimit: ethers.BigNumber,
    factoryDeps: BytesLike[],
    refundRecipient: string
) {
    let overrides = { gasPrice: 0 as BigNumberish, value: 0 as BigNumberish, gasLimit: 29000000 as BigNumberish };
    overrides.gasPrice = await mailbox.provider.getGasPrice();

    // we call bridgeheadChain direcetly to avoid running out of gas.
    const baseCost = await mailbox.l2TransactionBaseCost(
        overrides.gasPrice,
        ethers.BigNumber.from(100000),
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    overrides.value = baseCost.add(ethers.BigNumber.from(0));

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

export function genesisStoredBlockInfo(): StoredBlockInfo {
    return {
        blockNumber: 0,
        blockHash: ethers.constants.HashZero,
        indexRepeatedStorageChanges: 0,
        numberOfLayer1Txs: 0,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
        timestamp: 0,
        commitment: ethers.constants.HashZero
    };
}

// Packs the batch timestamp and block timestamp and returns the 32-byte hex string
// which should be used for the "key" field of the L2->L1 system context log.
export function packBatchTimestampAndBlockTimestamp(batchTimestamp: number, blockTimestamp: number): string {
    const packedNum = BigNumber.from(batchTimestamp).shl(128).or(BigNumber.from(blockTimestamp));
    return ethers.utils.hexZeroPad(ethers.utils.hexlify(packedNum), 32);
}

export interface StoredBlockInfo {
    blockNumber: BigNumberish;
    blockHash: BytesLike;
    indexRepeatedStorageChanges: BigNumberish;
    numberOfLayer1Txs: BigNumberish;
    priorityOperationsHash: BytesLike;
    l2LogsTreeRoot: BytesLike;
    timestamp: BigNumberish;
    commitment: BytesLike;
}

export interface CommitBlockInfo {
    blockNumber: BigNumberish;
    timestamp: number;
    indexRepeatedStorageChanges: BigNumberish;
    newStateRoot: BytesLike;
    numberOfLayer1Txs: BigNumberish;
    l2LogsTreeRoot: BytesLike;
    priorityOperationsHash: BytesLike;
    initialStorageChanges: BytesLike;
    repeatedStorageChanges: BytesLike;
    l2Logs: BytesLike;
    l2ArbitraryLengthMessages: BytesLike[];
    factoryDeps: BytesLike[];
}
