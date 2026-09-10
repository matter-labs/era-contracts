// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";

library StoredBatchHashing {
    /// @notice Returns the keccak hash of the ABI-encoded StoredBatchInfo
    function hashStoredBatchInfo(IExecutor.StoredBatchInfo memory _storedBatchInfo) internal pure returns (bytes32) {
        return keccak256(abi.encode(_storedBatchInfo));
    }

    /// @notice Returns the keccak hash of a StoredBatchInfo in its pre-Airbender form.
    /// @dev A batch committed before the lane existed was hashed without `airbenderCommitment`. It
    /// still has to authenticate, and it necessarily has no Airbender commitment to offer, so the
    /// caller must treat a batch that matches only this form as Boojum-only.
    function hashPreAirbenderStoredBatchInfo(
        IExecutor.StoredBatchInfo memory _storedBatchInfo
    ) internal pure returns (bytes32) {
        IExecutor.PreAirbenderStoredBatchInfo memory preAirbender = IExecutor.PreAirbenderStoredBatchInfo({
            batchNumber: _storedBatchInfo.batchNumber,
            batchHash: _storedBatchInfo.batchHash,
            indexRepeatedStorageChanges: _storedBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: _storedBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: _storedBatchInfo.priorityOperationsHash,
            dependencyRootsRollingHash: _storedBatchInfo.dependencyRootsRollingHash,
            l2LogsTreeRoot: _storedBatchInfo.l2LogsTreeRoot,
            timestamp: _storedBatchInfo.timestamp,
            commitment: _storedBatchInfo.commitment
        });
        return keccak256(abi.encode(preAirbender));
    }

    /// @notice Returns the keccak hash of the ABI-encoded Legacy StoredBatchInfo
    function hashLegacyStoredBatchInfo(
        IExecutor.StoredBatchInfo memory _storedBatchInfo
    ) internal pure returns (bytes32) {
        IExecutor.LegacyStoredBatchInfo memory legacyStoredBatchInfo = IExecutor.LegacyStoredBatchInfo({
            batchNumber: _storedBatchInfo.batchNumber,
            batchHash: _storedBatchInfo.batchHash,
            indexRepeatedStorageChanges: _storedBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: _storedBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: _storedBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: _storedBatchInfo.l2LogsTreeRoot,
            timestamp: _storedBatchInfo.timestamp,
            commitment: _storedBatchInfo.commitment
        });
        return keccak256(abi.encode(legacyStoredBatchInfo));
    }
}
