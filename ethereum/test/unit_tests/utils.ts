import { BigNumber, BytesLike, ethers } from 'ethers';
import { Address } from 'zksync-web3/build/src/types';

export const IERC20_INTERFACE = require('@openzeppelin/contracts/build/contracts/IERC20');
export const DEFAULT_REVERT_REASON = 'VM did not revert';

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
