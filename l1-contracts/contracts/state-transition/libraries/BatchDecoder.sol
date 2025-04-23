// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";
import {PriorityOpsBatchInfo} from "./PriorityTree.sol";
import {IncorrectBatchBounds, EmptyData, UnsupportedCommitBatchEncoding, UnsupportedProofBatchEncoding, UnsupportedExecuteBatchEncoding} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Utility library for decoding and validating batch data.
/// @dev This library decodes commit, proof, and execution batch data and verifies batch number bounds.
///      It reverts with custom errors when the data is invalid or unsupported encoding is used.
library BatchDecoder {
    /// @notice The currently supported encoding version.
    uint8 internal constant SUPPORTED_ENCODING_VERSION = 0;

    /// @notice Decodes commit data from a calldata bytes into the last committed batch data and an array of new batch data.
    /// @param _commitData The calldata byte array containing the data for committing batches.
    /// @return lastCommittedBatchData The data for the batch before newly committed batches.
    /// @return newBatchesData An array containing the newly committed batches.
    function _decodeCommitData(
        bytes calldata _commitData
    )
        private
        pure
        returns (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            IExecutor.CommitBatchInfo[] memory newBatchesData
        )
    {
        if (_commitData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_commitData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION) {
            (lastCommittedBatchData, newBatchesData) = abi.decode(
                _commitData[1:],
                (IExecutor.StoredBatchInfo, IExecutor.CommitBatchInfo[])
            );
        } else {
            revert UnsupportedCommitBatchEncoding(encodingVersion);
        }
    }

    /// @notice Decodes the commit data and checks that the provided batch bounds are correct.
    /// @dev Note that it only checks that the last and the first batches in the array correspond to the provided bounds.
    /// The fact that the batches inside the array are provided in the correct order should be checked by the caller.
    /// @param _commitData The calldata byte array containing the data for committing batches.
    /// @param _processBatchFrom The expected batch number of the first commit batch in the array.
    /// @param _processBatchTo The expected batch number of the last commit batch in the array.
    /// @return lastCommittedBatchData The data for the batch before newly committed batches.
    /// @return newBatchesData An array containing the newly committed batches.
    function decodeAndCheckCommitData(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    )
        internal
        pure
        returns (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            IExecutor.CommitBatchInfo[] memory newBatchesData
        )
    {
        (lastCommittedBatchData, newBatchesData) = _decodeCommitData(_commitData);

        if (newBatchesData.length == 0) {
            revert EmptyData();
        }

        if (
            newBatchesData[0].batchNumber != _processBatchFrom ||
            newBatchesData[newBatchesData.length - 1].batchNumber != _processBatchTo
        ) {
            revert IncorrectBatchBounds(
                _processBatchFrom,
                _processBatchTo,
                newBatchesData[0].batchNumber,
                newBatchesData[newBatchesData.length - 1].batchNumber
            );
        }
    }

    /// @notice Decodes proof data from a calldata byte array into the previous batch, an array of proved batches, and a proof array.
    /// @param _proofData The calldata byte array containing the data for proving batches.
    /// @return prevBatch The batch information before the batches to be verified.
    /// @return provedBatches An array containing the the batches to be verified.
    /// @return proof An array containing the proof for the verifier.
    function _decodeProofData(
        bytes calldata _proofData
    )
        private
        pure
        returns (
            IExecutor.StoredBatchInfo memory prevBatch,
            IExecutor.StoredBatchInfo[] memory provedBatches,
            uint256[] memory proof
        )
    {
        uint8 encodingVersion = uint8(_proofData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION) {
            (prevBatch, provedBatches, proof) = abi.decode(
                _proofData[1:],
                (IExecutor.StoredBatchInfo, IExecutor.StoredBatchInfo[], uint256[])
            );
        } else {
            revert UnsupportedProofBatchEncoding(encodingVersion);
        }
    }

    /// @notice Decodes the commit data and checks that the provided batch bounds are correct.
    /// @dev Note that it only checks that the last and the first batches in the array correspond to the provided bounds.
    /// The fact that the batches inside the array are provided in the correct order should be checked by the caller.
    /// @param _proofData The commit data to decode.
    /// @param _processBatchFrom The expected batch number of the first batch in the array.
    /// @param _processBatchTo The expected batch number of the last batch in the array.
    /// @return prevBatch The batch information before the batches to be verified.
    /// @return provedBatches An array containing the the batches to be verified.
    /// @return proof An array containing the proof for the verifier.
    function decodeAndCheckProofData(
        bytes calldata _proofData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    )
        internal
        pure
        returns (
            IExecutor.StoredBatchInfo memory prevBatch,
            IExecutor.StoredBatchInfo[] memory provedBatches,
            uint256[] memory proof
        )
    {
        (prevBatch, provedBatches, proof) = _decodeProofData(_proofData);

        if (provedBatches.length == 0) {
            revert EmptyData();
        }

        if (
            provedBatches[0].batchNumber != _processBatchFrom ||
            provedBatches[provedBatches.length - 1].batchNumber != _processBatchTo
        ) {
            revert IncorrectBatchBounds(
                _processBatchFrom,
                _processBatchTo,
                provedBatches[0].batchNumber,
                provedBatches[provedBatches.length - 1].batchNumber
            );
        }
    }

    /// @notice Decodes execution data from a calldata byte array into an array of stored batch information.
    /// @param _executeData The calldata byte array containing the execution data to decode.
    /// @return executeData An array containing the stored batch information for execution.
    /// @return priorityOpsData Merkle proofs of the priority operations for each batch.
    function _decodeExecuteData(
        bytes calldata _executeData
    )
        private
        pure
        returns (IExecutor.StoredBatchInfo[] memory executeData, PriorityOpsBatchInfo[] memory priorityOpsData)
    {
        if (_executeData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_executeData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION) {
            (executeData, priorityOpsData) = abi.decode(
                _executeData[1:],
                (IExecutor.StoredBatchInfo[], PriorityOpsBatchInfo[])
            );
        } else {
            revert UnsupportedExecuteBatchEncoding(encodingVersion);
        }
    }

    /// @notice Decodes the execute data and checks that the provided batch bounds are correct.
    /// @dev Note that it only checks that the last and the first batches in the array correspond to the provided bounds.
    /// The fact that the batches inside the array are provided in the correct order should be checked by the caller.
    /// @param _executeData The calldata byte array containing the execution data to decode.
    /// @param _processBatchFrom The expected batch number of the first batch in the array.
    /// @param _processBatchTo The expected batch number of the last batch in the array.
    /// @return executeData An array containing the stored batch information for execution.
    /// @return priorityOpsData Merkle proofs of the priority operations for each batch.
    function decodeAndCheckExecuteData(
        bytes calldata _executeData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    )
        internal
        pure
        returns (IExecutor.StoredBatchInfo[] memory executeData, PriorityOpsBatchInfo[] memory priorityOpsData)
    {
        (executeData, priorityOpsData) = _decodeExecuteData(_executeData);

        if (executeData.length == 0) {
            revert EmptyData();
        }

        if (
            executeData[0].batchNumber != _processBatchFrom ||
            executeData[executeData.length - 1].batchNumber != _processBatchTo
        ) {
            revert IncorrectBatchBounds(
                _processBatchFrom,
                _processBatchTo,
                executeData[0].batchNumber,
                executeData[executeData.length - 1].batchNumber
            );
        }
    }
}
