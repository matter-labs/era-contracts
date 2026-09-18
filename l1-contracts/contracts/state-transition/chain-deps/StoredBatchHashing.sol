// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";

library StoredBatchHashing {
    /// @notice Returns the keccak hash of the ABI-encoded StoredBatchInfo
    function hashStoredBatchInfo(IExecutor.StoredBatchInfo memory _storedBatchInfo) internal pure returns (bytes32) {
        return keccak256(abi.encode(_storedBatchInfo));
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
