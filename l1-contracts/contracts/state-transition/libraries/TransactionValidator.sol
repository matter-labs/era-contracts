// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";

import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {
    L1_TX_CALLDATA_FLOOR_PRICE_L2_GAS_ZKSYNC_OS,
    L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS,
    L1_TX_INTRINSIC_PUBDATA_ZKSYNC_OS,
    L1_TX_NATIVE_PER_GAS,
    MAX_NATIVE_COMPUTATIONAL_ZKSYNC_OS
} from "../../common/Config.sol";
import {
    InvalidUpgradeTxn,
    PubdataGreaterThanLimit,
    TooMuchGas,
    UpgradeTxVerifyParam,
    ValidateTxnNotEnoughGas
} from "../../common/L1ContractErrors.sol";

/// @title ZKsync Library for validating L1 -> L2 transactions
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library TransactionValidator {
    /// @dev Used to validate key properties of an L1->L2 transaction
    /// @param _transaction The transaction to validate
    /// @param _priorityTxMaxGasLimit The max gas limit, generally provided from Storage.sol
    /// @param _priorityTxMaxPubdata The maximal amount of pubdata that a single L1->L2 transaction can emit
    function validateL1ToL2Transaction(
        L2CanonicalTransaction memory _transaction,
        uint256 _priorityTxMaxGasLimit,
        uint256 _priorityTxMaxPubdata
    ) internal pure {
        // ZKsync OS has no batch overhead, so the whole gas limit is the transaction body's.
        uint256 l2GasForTxBody = _transaction.gasLimit;

        // Ensuring that the transaction is provable
        if (l2GasForTxBody > _priorityTxMaxGasLimit) {
            revert TooMuchGas();
        }
        // Ensuring that the transaction cannot output more pubdata than is processable
        if (l2GasForTxBody / _transaction.gasPerPubdataByteLimit > _priorityTxMaxPubdata) {
            revert PubdataGreaterThanLimit(_priorityTxMaxPubdata, l2GasForTxBody / _transaction.gasPerPubdataByteLimit);
        }

        // Ensuring that the transaction covers the minimal costs for its processing:
        // hashing its content, publishing the factory dependencies, etc.
        if (
            getMinimalPriorityTransactionGasLimit(_transaction.data.length, _transaction.gasPerPubdataByteLimit) >
            l2GasForTxBody
        ) {
            revert ValidateTxnNotEnoughGas();
        }
    }

    /// @dev Used to validate upgrade transactions
    /// @param _transaction The transaction to validate
    function validateUpgradeTransaction(L2CanonicalTransaction memory _transaction) internal pure {
        // Restrict from to be within system contract range (0...2^16 - 1)
        if (_transaction.from > type(uint16).max) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.From);
        }
        if (_transaction.to > type(uint160).max) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.To);
        }
        if (_transaction.paymaster != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Paymaster);
        }
        if (_transaction.value != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Value);
        }
        if (_transaction.maxFeePerGas != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.MaxFeePerGas);
        }
        if (_transaction.maxPriorityFeePerGas != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.MaxPriorityFeePerGas);
        }
        if (_transaction.reserved[0] != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Reserved0);
        }
        if (_transaction.reserved[1] > type(uint160).max) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Reserved1);
        }
        if (_transaction.reserved[2] != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Reserved2);
        }
        if (_transaction.reserved[3] != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Reserved3);
        }
        if (_transaction.signature.length != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.Signature);
        }
        if (_transaction.paymasterInput.length != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.PaymasterInput);
        }
        if (_transaction.reservedDynamic.length != 0) {
            revert InvalidUpgradeTxn(UpgradeTxVerifyParam.ReservedDynamic);
        }
    }

    /// @dev Calculates the approximate minimum gas limit required for executing a priority transaction.
    /// @param _calldataLength The length of the transaction's calldata in bytes.
    /// @param _l2GasPricePerPubdata The L2 gas price for publishing the priority transaction on L2.
    /// @return The minimum gas limit required to execute the priority transaction.
    /// Note: The calculation includes the main cost of the priority transaction, however, in reality, the operator can spend a little more gas on overheads.
    function getMinimalPriorityTransactionGasLimit(
        uint256 _calldataLength,
        uint256 _l2GasPricePerPubdata
    ) internal pure returns (uint256) {
        // Due to double account resources model in zksync os, we need to calculate 2 things for minimal gas limit:
        // 1. Intrinsic tx cost in gas
        // 2. Intrinsic tx cost in native resources
        // And then take the bigger value

        // 1. Intrinsic tx cost in gas
        uint256 intrinsicGasCost = L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS;
        // we are overcharging using floor non-zero byte cost to cover the worst case
        intrinsicGasCost += L1_TX_CALLDATA_FLOOR_PRICE_L2_GAS_ZKSYNC_OS * _calldataLength;

        // 2. Intrinsic tx cost in native resources
        // Since we are using huge `L1_TX_NATIVE_PER_GAS` ratio, it mostly consists of pubdata cost.
        uint256 intrinsicPubdataGasCost = L1_TX_INTRINSIC_PUBDATA_ZKSYNC_OS * _l2GasPricePerPubdata;
        // And because of huge ratio, we are overestimating using `MAX_NATIVE_COMPUTATIONAL_ZKSYNC_OS`.
        // Actual intrinsic cost is much lower, but even with `MAX_NATIVE_COMPUTATIONAL_ZKSYNC_OS`
        // it will be around 343 gas and overestimate makes code safer and easier to support
        uint256 gasForIntrinsicNative = intrinsicPubdataGasCost +
            Math.ceilDiv(MAX_NATIVE_COMPUTATIONAL_ZKSYNC_OS, L1_TX_NATIVE_PER_GAS);

        return Math.max(intrinsicGasCost, gasForIntrinsicNative);
    }
}
