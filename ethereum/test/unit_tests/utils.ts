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
    timestamp: BigNumberish;
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
