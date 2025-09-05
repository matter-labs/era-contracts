// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";

import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {L1_TX_DELTA_544_ENCODING_BYTES, L1_TX_DELTA_FACTORY_DEPS_L2_GAS, L1_TX_DELTA_FACTORY_DEPS_PUBDATA, L1_TX_INTRINSIC_L2_GAS, L1_TX_INTRINSIC_PUBDATA, L1_TX_MIN_L2_GAS_BASE, MEMORY_OVERHEAD_GAS, TX_SLOT_OVERHEAD_L2_GAS, ZKSYNC_OS_L1_TX_NATIVE_PRICE, L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS, L1_TX_CALLDATA_PRICE_L2_GAS_ZKSYNC_OS, L1_TX_STATIC_NATIVE_ZKSYNC_OS, L1_TX_ENCODING_136_BYTES_COST_NATIVE_ZKSYNC_OS, L1_TX_INTRINSIC_PUBDATA_ZSKYNC_OS, L1_TX_MINIMAL_GAS_LIMIT_ZSKYNC_OS, L1_TX_CALLDATA_COST_NATIVE_ZKSYNC_OS, UPGRADE_TX_NATIVE_PER_GAS, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "../../common/Config.sol";
import {InvalidUpgradeTxn, PubdataGreaterThanLimit, TooMuchGas, TxnBodyGasLimitNotEnoughGas, UpgradeTxVerifyParam, ValidateTxnNotEnoughGas, ZeroGasPriceL1TxZKSyncOS} from "../../common/L1ContractErrors.sol";

/// @title ZKsync Library for validating L1 -> L2 transactions
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library TransactionValidator {
    /// @dev Used to validate key properties of an L1->L2 transaction
    /// @param _transaction The transaction to validate
    /// @param _encoded The abi encoded bytes of the transaction
    /// @param _priorityTxMaxGasLimit The max gas limit, generally provided from Storage.sol
    /// @param _priorityTxMaxPubdata The maximal amount of pubdata that a single L1->L2 transaction can emit
    /// @param zksyncOS ZKsync OS state transition flag
    function validateL1ToL2Transaction(
        L2CanonicalTransaction memory _transaction,
        bytes memory _encoded,
        uint256 _priorityTxMaxGasLimit,
        uint256 _priorityTxMaxPubdata,
        bool zksyncOS
    ) internal pure {
        uint256 l2GasForTxBody = getTransactionBodyGasLimit(_transaction.gasLimit, _encoded.length, zksyncOS);

        // Ensuring that the transaction is provable
        if (l2GasForTxBody > _priorityTxMaxGasLimit) {
            revert TooMuchGas();
        }
        // Ensuring that the transaction cannot output more pubdata than is processable
        if (l2GasForTxBody / _transaction.gasPerPubdataByteLimit > _priorityTxMaxPubdata) {
            revert PubdataGreaterThanLimit(_priorityTxMaxPubdata, l2GasForTxBody / _transaction.gasPerPubdataByteLimit);
        }

        // Currently we don't support L1->L2 transactions with 0 `maxFeePerGas` in ZKSyncOS,
        // it's allowed only for upgrade transactions.
        // It should be ensured by constants in FeeParams, although we are double-checking it just in case.
        if (zksyncOS && _transaction.maxFeePerGas == 0 && _transaction.txType != ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE) {
            revert ZeroGasPriceL1TxZKSyncOS();
        }

        // Ensuring that the transaction covers the minimal costs for its processing:
        // hashing its content, publishing the factory dependencies, etc.
        if (
            // solhint-disable-next-line func-named-parameters
            getMinimalPriorityTransactionGasLimit(
                _encoded.length,
                _transaction.data.length,
                _transaction.factoryDeps.length,
                _transaction.gasPerPubdataByteLimit,
                _transaction.maxFeePerGas,
                zksyncOS
            ) > l2GasForTxBody
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
    /// @param _encodingLength The length of the priority transaction encoding in bytes.
    /// @param _numberOfFactoryDependencies The number of new factory dependencies that will be added.
    /// @param _l2GasPricePerPubdata The L2 gas price for publishing the priority transaction on L2.
    /// @param _maxFeePerGas The maximal gas price for the transaction.
    /// @param zksyncOS ZKsync OS state transition flag
    /// @return The minimum gas limit required to execute the priority transaction.
    /// Note: The calculation includes the main cost of the priority transaction, however, in reality, the operator can spend a little more gas on overheads.
    function getMinimalPriorityTransactionGasLimit(
        uint256 _encodingLength,
        uint256 _calldataLength,
        uint256 _numberOfFactoryDependencies,
        uint256 _l2GasPricePerPubdata,
        uint256 _maxFeePerGas,
        bool zksyncOS
    ) internal pure returns (uint256) {
        if (zksyncOS) {
            uint256 gasCost = L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS;
            // we are always a bit overcharging for zero bytes
            gasCost += L1_TX_CALLDATA_PRICE_L2_GAS_ZKSYNC_OS * _calldataLength;

            uint256 nativeComputationalCost = L1_TX_STATIC_NATIVE_ZKSYNC_OS; // static computational native part
            nativeComputationalCost +=
                Math.max(1, Math.ceilDiv(_encodingLength, 136)) *
                L1_TX_ENCODING_136_BYTES_COST_NATIVE_ZKSYNC_OS; // dynamic computational native part for hashing
            nativeComputationalCost += _calldataLength * L1_TX_CALLDATA_COST_NATIVE_ZKSYNC_OS; // dynamic computational part for calldata
            uint256 gasNeededToCoverComputationalNative;
            // 0 gas price is possible only for upgrade transactions currently, it's validated before calling this method.
            // In the future, we may redesign our fee model to support zero gas price for L1->L2 transactions.
            if (_maxFeePerGas == 0) {
                gasNeededToCoverComputationalNative = nativeComputationalCost / UPGRADE_TX_NATIVE_PER_GAS;
            } else {
                gasNeededToCoverComputationalNative =
                    (nativeComputationalCost * ZKSYNC_OS_L1_TX_NATIVE_PRICE) /
                    _maxFeePerGas;
            }

            uint256 pubdataGasCost = L1_TX_INTRINSIC_PUBDATA_ZSKYNC_OS * _l2GasPricePerPubdata;

            uint256 totalGasForNative = gasNeededToCoverComputationalNative + pubdataGasCost;

            // We have `L1_TX_MINIMAL_GAS_LIMIT_ZSKYNC_OS` to be extra safe
            return Math.max(Math.max(gasCost, totalGasForNative), L1_TX_MINIMAL_GAS_LIMIT_ZSKYNC_OS);
        } else {
            uint256 costForComputation;
            {
                // Adding the intrinsic cost for the transaction, i.e. auxiliary prices which cannot be easily accounted for
                costForComputation = L1_TX_INTRINSIC_L2_GAS;

                // Taking into account the hashing costs that depend on the length of the transaction
                // Note that L1_TX_DELTA_544_ENCODING_BYTES is the delta in the price for every 544 bytes of
                // the transaction's encoding. It is taken as LCM between 136 and 32 (the length for each keccak256 round
                // and the size of each new encoding word).
                costForComputation += Math.ceilDiv(_encodingLength * L1_TX_DELTA_544_ENCODING_BYTES, 544);

                // Taking into the account the additional costs of providing new factory dependencies
                costForComputation += _numberOfFactoryDependencies * L1_TX_DELTA_FACTORY_DEPS_L2_GAS;

                // There is a minimal amount of computational L2 gas that the transaction should cover
                costForComputation = Math.max(costForComputation, L1_TX_MIN_L2_GAS_BASE);
            }

            uint256 costForPubdata = 0;
            {
                // Adding the intrinsic cost for the transaction, i.e. auxiliary prices which cannot be easily accounted for
                costForPubdata = L1_TX_INTRINSIC_PUBDATA * _l2GasPricePerPubdata;

                // Taking into the account the additional costs of providing new factory dependencies
                costForPubdata +=
                    _numberOfFactoryDependencies *
                    L1_TX_DELTA_FACTORY_DEPS_PUBDATA *
                    _l2GasPricePerPubdata;
            }

            return costForComputation + costForPubdata;
        }
    }

    /// @notice Based on the full L2 gas limit (that includes the batch overhead) and other
    /// properties of the transaction, returns the l2GasLimit for the body of the transaction (the actual execution).
    /// @param _totalGasLimit The L2 gas limit that includes both the overhead for processing the batch
    /// and the L2 gas needed to process the transaction itself (i.e. the actual l2GasLimit that will be used for the transaction).
    /// @param _encodingLength The length of the ABI-encoding of the transaction.
    /// @param zksyncOS ZKsync OS state transition flag
    function getTransactionBodyGasLimit(
        uint256 _totalGasLimit,
        uint256 _encodingLength,
        bool zksyncOS
    ) internal pure returns (uint256 txBodyGasLimit) {
        // There is no overhead in ZKsync OS
        if (zksyncOS) {
            return _totalGasLimit;
        }
        uint256 overhead = getOverheadForTransaction(_encodingLength);

        // provided gas limit doesn't cover transaction overhead
        if (_totalGasLimit < overhead) {
            revert TxnBodyGasLimitNotEnoughGas();
        }
        unchecked {
            // We enforce the fact that `_totalGasLimit >= overhead` explicitly above.
            txBodyGasLimit = _totalGasLimit - overhead;
        }
    }

    /// @notice Based on the total L2 gas limit and several other parameters of the transaction
    /// returns the part of the L2 gas that will be spent on the batch's overhead.
    /// @dev The details of how this function works can be checked in the documentation
    /// of the fee model of ZKsync. The appropriate comments are also present
    /// in the Rust implementation description of function `get_maximal_allowed_overhead`.
    /// @param _encodingLength The length of the binary encoding of the transaction in bytes
    function getOverheadForTransaction(
        uint256 _encodingLength
    ) internal pure returns (uint256 batchOverheadForTransaction) {
        // The overhead from taking up the transaction's slot
        batchOverheadForTransaction = TX_SLOT_OVERHEAD_L2_GAS;

        // The overhead for occupying the bootloader memory can be derived from encoded_len
        uint256 overheadForLength = MEMORY_OVERHEAD_GAS * _encodingLength;
        batchOverheadForTransaction = Math.max(batchOverheadForTransaction, overheadForLength);
    }
}
