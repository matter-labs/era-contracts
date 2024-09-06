// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";

import { IncorrectBatchBounds, EmptyData, UnsupportedCommitBatchEncoding, UnsupportedProofBatchEncoding, UnsupportedExecuteBatchEncoding } from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The helper library for
library BatchDecoder {
    /// @notice The currently supported encoding version.
    uint8 internal constant SUPPORTED_ENCODING_VERSION = 0;

    function decodeCommitData(
        bytes calldata _commitData
    )
        internal
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
    /// @param _commitData The commit data to decode.
    /// @param _processBatchFrom The expected batch number of the first batch in the array.
    /// @param _processBatchTo The expected batch number of the last batch in the array.
    function decodeAndCheckCommitData(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) internal pure returns (IExecutor.StoredBatchInfo memory lastCommittedBatchData, IExecutor.CommitBatchInfo[] memory newBatchesData) {
        (lastCommittedBatchData, newBatchesData) = decodeCommitData(_commitData);

        if (newBatchesData.length == 0) {
            revert EmptyData();
        }

        if (newBatchesData[0].batchNumber != _processBatchFrom) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, newBatchesData[0].batchNumber, newBatchesData[newBatchesData.length - 1].batchNumber);
        }

        if (newBatchesData[newBatchesData.length - 1].batchNumber != _processBatchTo) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, newBatchesData[0].batchNumber, newBatchesData[newBatchesData.length - 1].batchNumber);
        }
    }

    function decodeProofData(
        bytes calldata _proofData
    )
        internal
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
    function decodeAndCheckProofData(
        bytes calldata _proofData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) internal pure returns (
            IExecutor.StoredBatchInfo memory prevBatch,
            IExecutor.StoredBatchInfo[] memory provedBatches,
            uint256[] memory proof
    ) {
        (prevBatch, provedBatches, proof) = decodeProofData(_proofData);

        if (provedBatches.length == 0) {
            revert EmptyData();
        }

        if (provedBatches[0].batchNumber != _processBatchFrom) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, provedBatches[0].batchNumber, provedBatches[provedBatches.length - 1].batchNumber);
        }

        if (provedBatches[provedBatches.length - 1].batchNumber != _processBatchTo) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, provedBatches[0].batchNumber, provedBatches[provedBatches.length - 1].batchNumber);
        }
    }

    function decodeExecuteData(
        bytes calldata _executeData
    ) internal pure returns (IExecutor.StoredBatchInfo[] memory executeData) {
        if (_executeData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_executeData[0]);
        if (encodingVersion == 0) {
            (executeData) = abi.decode(_executeData[1:], (IExecutor.StoredBatchInfo[]));
        } else {
            revert UnsupportedExecuteBatchEncoding(encodingVersion);
        }
    }

    /// @notice Decodes the execute data and checks that the provided batch bounds are correct.
    /// @dev Note that it only checks that the last and the first batches in the array correspond to the provided bounds.
    /// The fact that the batches inside the array are provided in the correct order should be checked by the caller.
    /// @param _executeData The execute data to decode.
    /// @param _processBatchFrom The expected batch number of the first batch in the array.
    /// @param _processBatchTo The expected batch number of the last batch in the array.
    function decodeAndCheckExecuteData(
        bytes calldata _executeData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) internal pure returns (IExecutor.StoredBatchInfo[] memory executeData) {
        executeData = decodeExecuteData(_executeData);

        if (executeData.length == 0) {
            revert EmptyData();
        }

        if (executeData[0].batchNumber != _processBatchFrom) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, executeData[0].batchNumber, executeData[executeData.length - 1].batchNumber);
        }

        if (executeData[executeData.length - 1].batchNumber != _processBatchTo) {
            revert IncorrectBatchBounds(_processBatchFrom, _processBatchTo, executeData[0].batchNumber, executeData[executeData.length - 1].batchNumber);
        }
    }
}
