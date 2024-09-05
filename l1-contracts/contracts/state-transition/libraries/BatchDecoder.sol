// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The helper library for
library BatchDecoder {
    error EmptyData();

    error UnsupportedCommitBatchEncoding(uint8 version);

    error UnsupportedProofBatchEncoding(uint8 version);

    error UnsupportedExecuteBatchEncoding(uint8 version);

    function decodeCommitData(
        bytes calldata _commitData
    )
        internal
        view
        returns (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            IExecutor.CommitBatchInfo[] memory newBatchesData
        )
    {
        if (_commitData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_commitData[0]);
        if (encodingVersion == 0) {
            (lastCommittedBatchData, newBatchesData) = abi.decode(
                _commitData[1:],
                (IExecutor.StoredBatchInfo, IExecutor.CommitBatchInfo[])
            );
        } else {
            revert UnsupportedCommitBatchEncoding(encodingVersion);
        }
    }

    function decodeProofData(
        bytes calldata _proofData
    )
        internal
        view
        returns (
            IExecutor.StoredBatchInfo memory prevBatch,
            IExecutor.StoredBatchInfo[] memory committedBatches,
            uint256[] memory proof
        )
    {
        if (_proofData.length == 0) {
            revert EmptyData();
        }

        uint8 encodingVersion = uint8(_proofData[0]);
        if (encodingVersion == 0) {
            (prevBatch, committedBatches, proof) = abi.decode(
                _proofData[1:],
                (IExecutor.StoredBatchInfo, IExecutor.StoredBatchInfo[], uint256[])
            );
        } else {
            revert UnsupportedProofBatchEncoding(encodingVersion);
        }
    }

    function decodeExecuteData(
        bytes calldata _executeData
    ) internal view returns (IExecutor.StoredBatchInfo[] memory executeData) {
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
}
