// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {L2CanonicalTransaction} from "../../common/Messaging.sol";
import {TX_SLOT_OVERHEAD_L2_GAS, MEMORY_OVERHEAD_GAS, L1_TX_INTRINSIC_L2_GAS, L1_TX_DELTA_544_ENCODING_BYTES, L1_TX_DELTA_FACTORY_DEPS_L2_GAS, L1_TX_MIN_L2_GAS_BASE, L1_TX_INTRINSIC_PUBDATA, L1_TX_DELTA_FACTORY_DEPS_PUBDATA} from "../../common/Config.sol";

/// @title zkSync Library for validating L1 -> L2 transactions
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library TransactionValidator {
    /// @dev Used to validate key properties of an L1->L2 transaction
    /// @param _transaction The transaction to validate
    /// @param _encoded The abi encoded bytes of the transaction
    /// @param _priorityTxMaxGasLimit The max gas limit, generally provided from Storage.sol
    /// @param _priorityTxMaxPubdata The maximal amount of pubdata that a single L1->L2 transaction can emit
    function validateL1ToL2Transaction(
        L2CanonicalTransaction memory _transaction,
        bytes memory _encoded,
        uint256 _priorityTxMaxGasLimit,
        uint256 _priorityTxMaxPubdata
    ) internal pure {
        uint256 l2GasForTxBody = getTransactionBodyGasLimit(_transaction.gasLimit, _encoded.length);

        // Ensuring that the transaction is provable
        require(l2GasForTxBody <= _priorityTxMaxGasLimit, "ui");
        // Ensuring that the transaction cannot output more pubdata than is processable
        require(l2GasForTxBody / _transaction.gasPerPubdataByteLimit <= _priorityTxMaxPubdata, "uk");

        // Ensuring that the transaction covers the minimal costs for its processing:
        // hashing its content, publishing the factory dependencies, etc.
        require(
            getMinimalPriorityTransactionGasLimit(
                _encoded.length,
                _transaction.factoryDeps.length,
                _transaction.gasPerPubdataByteLimit
            ) <= l2GasForTxBody,
            "up"
        );
    }

    /// @dev Used to validate upgrade transactions
    /// @param _transaction The transaction to validate
    function validateUpgradeTransaction(L2CanonicalTransaction memory _transaction) internal pure {
        // Restrict from to be within system contract range (0...2^16 - 1)
        require(_transaction.from <= type(uint16).max, "ua");
        require(_transaction.to <= type(uint160).max, "ub");
        require(_transaction.paymaster == 0, "uc");
        require(_transaction.value == 0, "ud");
        require(_transaction.maxFeePerGas == 0, "uq");
        require(_transaction.maxPriorityFeePerGas == 0, "ux");
        require(_transaction.reserved[0] == 0, "ue");
        require(_transaction.reserved[1] <= type(uint160).max, "uf");
        require(_transaction.reserved[2] == 0, "ug");
        require(_transaction.reserved[3] == 0, "uo");
        require(_transaction.signature.length == 0, "uh");
        require(_transaction.paymasterInput.length == 0, "ul1");
        require(_transaction.reservedDynamic.length == 0, "um");
    }

    /// @dev Calculates the approximate minimum gas limit required for executing a priority transaction.
    /// @param _encodingLength The length of the priority transaction encoding in bytes.
    /// @param _numberOfFactoryDependencies The number of new factory dependencies that will be added.
    /// @param _l2GasPricePerPubdata The L2 gas price for publishing the priority transaction on L2.
    /// @return The minimum gas limit required to execute the priority transaction.
    /// Note: The calculation includes the main cost of the priority transaction, however, in reality, the operator can spend a little more gas on overheads.
    function getMinimalPriorityTransactionGasLimit(
        uint256 _encodingLength,
        uint256 _numberOfFactoryDependencies,
        uint256 _l2GasPricePerPubdata
    ) internal pure returns (uint256) {
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
            costForPubdata += _numberOfFactoryDependencies * L1_TX_DELTA_FACTORY_DEPS_PUBDATA * _l2GasPricePerPubdata;
        }

        return costForComputation + costForPubdata;
    }

    /// @notice Based on the full L2 gas limit (that includes the batch overhead) and other
    /// properties of the transaction, returns the l2GasLimit for the body of the transaction (the actual execution).
    /// @param _totalGasLimit The L2 gas limit that includes both the overhead for processing the batch
    /// and the L2 gas needed to process the transaction itself (i.e. the actual l2GasLimit that will be used for the transaction).
    /// @param _encodingLength The length of the ABI-encoding of the transaction.
    function getTransactionBodyGasLimit(
        uint256 _totalGasLimit,
        uint256 _encodingLength
    ) internal pure returns (uint256 txBodyGasLimit) {
        uint256 overhead = getOverheadForTransaction(_encodingLength);

        require(_totalGasLimit >= overhead, "my"); // provided gas limit doesn't cover transaction overhead
        unchecked {
            // We enforce the fact that `_totalGasLimit >= overhead` explicitly above.
            txBodyGasLimit = _totalGasLimit - overhead;
        }
    }

    /// @notice Based on the total L2 gas limit and several other parameters of the transaction
    /// returns the part of the L2 gas that will be spent on the batch's overhead.
    /// @dev The details of how this function works can be checked in the documentation
    /// of the fee model of zkSync. The appropriate comments are also present
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
