// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";
import {PriorityOpsBatchInfo} from "./PriorityTree.sol";
import {EmptyData, IncorrectBatchBounds, UnsupportedCommitBatchEncoding, UnsupportedExecuteBatchEncoding, UnsupportedProofBatchEncoding} from "../../common/L1ContractErrors.sol";
import {InteropRoot, L2Log} from "../../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Utility library for decoding and validating batch data.
/// @dev This library decodes commit, proof, and execution batch data and verifies batch number bounds.
///      It reverts with custom errors when the data is invalid or unsupported encoding is used.
library BatchDecoder {
    /// @notice The currently supported encoding version.
    uint8 internal constant SUPPORTED_ENCODING_VERSION = 1;
    /// @notice The currently supported encoding version for ZKSync OS commit data.
    /// We use different encoding only for commit, while prove/execute are common for Era VM and ZKsync OS chains.
    uint8 internal constant SUPPORTED_ENCODING_VERSION_COMMIT_ZKSYNC_OS = 3;

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

    // exactly the same as regular `_decodeCommitData`, except for 2 differences:
    // - encoding version is different
    // - uses different structure for the commit batch info
    function _decodeCommitDataZKsyncOS(
        bytes calldata _commitData
    )
        private
        pure
        returns (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            IExecutor.CommitBatchInfoZKsyncOS[] memory newBatchesData
        )
    {
        if (_commitData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_commitData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION_COMMIT_ZKSYNC_OS) {
            (lastCommittedBatchData, newBatchesData) = abi.decode(
                _commitData[1:],
                (IExecutor.StoredBatchInfo, IExecutor.CommitBatchInfoZKsyncOS[])
            );
        } else {
            revert UnsupportedCommitBatchEncoding(encodingVersion);
        }
    }

    /// @notice Decodes and validates precommit data for a batch, ensuring the encoding version is supported.
    /// @dev The first byte of `_precommitData` is interpreted as the encoding version and must equal `SUPPORTED_ENCODING_VERSION`.
    ///      If it does, the remainder of the data is decoded into an `IExecutor.PrecommitInfo` struct. Otherwise, this call reverts.
    /// @param _precommitData ABI-encoded bytes where the first byte is the encoding version, followed by the encoded `PrecommitInfo`.
    /// @return precommitInfo The decoded `PrecommitInfo` containing transaction status commitments.
    function decodeAndCheckPrecommitData(
        bytes calldata _precommitData
    ) internal pure returns (IExecutor.PrecommitInfo memory precommitInfo) {
        if (_precommitData.length == 0) {
            revert EmptyData();
        }
        uint8 encodingVersion = uint8(_precommitData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION) {
            (precommitInfo) = abi.decode(_precommitData[1:], (IExecutor.PrecommitInfo));
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

    // exactly the same as regular `decodeAndCheckCommitData`, except for one difference:
    // uses different structure for the commit batch info
    function decodeAndCheckCommitDataZKsyncOS(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    )
        internal
        pure
        returns (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            IExecutor.CommitBatchInfoZKsyncOS[] memory newBatchesData
        )
    {
        (lastCommittedBatchData, newBatchesData) = _decodeCommitDataZKsyncOS(_commitData);

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
        if (_proofData.length == 0) {
            revert EmptyData();
        }
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
        returns (
            IExecutor.StoredBatchInfo[] memory executeData,
            PriorityOpsBatchInfo[] memory priorityOpsData,
            InteropRoot[][] memory dependencyRoots,
            L2Log[][] memory logs,
            bytes[][] memory messages,
            bytes32[] memory messageRoots
        )
    {
        if (_executeData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_executeData[0]);
        if (encodingVersion == SUPPORTED_ENCODING_VERSION) {
            (executeData, priorityOpsData, dependencyRoots, logs, messages, messageRoots) = abi.decode(
                _executeData[1:],
                (IExecutor.StoredBatchInfo[], PriorityOpsBatchInfo[], InteropRoot[][], L2Log[][], bytes[][], bytes32[])
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
        returns (
            IExecutor.StoredBatchInfo[] memory executeData,
            PriorityOpsBatchInfo[] memory priorityOpsData,
            InteropRoot[][] memory dependencyRoots,
            L2Log[][] memory logs,
            bytes[][] memory messages,
            bytes32[] memory messageRoots
        )
    {
        (executeData, priorityOpsData, dependencyRoots, logs, messages, messageRoots) = _decodeExecuteData(
            _executeData
        );

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
