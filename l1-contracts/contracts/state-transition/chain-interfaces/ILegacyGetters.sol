// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IZkSyncHyperchainBase} from "./IZkSyncHyperchainBase.sol";

/// @author Matter Labs
/// @dev This interface contains getters for the zkSync contract that should not be used,
/// but still are kept for backward compatibility.
/// @custom:security-contact security@matterlabs.dev
interface ILegacyGetters is IZkSyncHyperchainBase {
    /// @return The total number of batches that were committed
    /// @dev It is a *deprecated* method, please use `getTotalBatchesCommitted` instead
    function getTotalBlocksCommitted() external view returns (uint256);

    /// @return The total number of batches that were committed & verified
    /// @dev It is a *deprecated* method, please use `getTotalBatchesVerified` instead.
    function getTotalBlocksVerified() external view returns (uint256);

    /// @return The total number of batches that were committed & verified & executed
    /// @dev It is a *deprecated* method, please use `getTotalBatchesExecuted` instead.
    function getTotalBlocksExecuted() external view returns (uint256);

    /// @notice For unfinalized (non executed) batches may change
    /// @dev It is a *deprecated* method, please use `storedBatchHash` instead.
    /// @dev returns zero for non-committed batches
    /// @return The hash of committed L2 batch.
    function storedBlockHash(uint256 _batchNumber) external view returns (bytes32);

    /// @return The L2 batch number in which the upgrade transaction was processed.
    /// @dev It is a *deprecated* method, please use `getL2SystemContractsUpgradeBatchNumber` instead.
    /// @dev It is equal to 0 in the following two cases:
    /// - No upgrade transaction has ever been processed.
    /// - The upgrade transaction has been processed and the batch with such transaction has been
    /// executed (i.e. finalized).
    function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256);
}
