// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MigrationInterval} from "./IChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1ChainAssetHandler {
    function isMigrationInProgress(uint256 _chainId) external view returns (bool);

    /// @notice Returns the migration interval for a chain at a specific migration number.
    /// @param _chainId The ID of the chain.
    /// @param _migrationNumber The migration number (0 for legacy GW, 1+ for regular migrations).
    /// @return interval The migration interval data.
    function migrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber
    ) external view returns (MigrationInterval memory interval);

    /// @notice Sets a historical migration interval for a chain.
    /// @dev Only callable by owner. Used to set legacy GW migration data for chains that used the old GW.
    /// @param _chainId The ID of the chain.
    /// @param _migrationNumber The migration number to set.
    /// @param _interval The migration interval data.
    function setHistoricalMigrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber,
        MigrationInterval calldata _interval
    ) external;

    /// @notice Validates if a claimed settlement layer is valid for a given chain and batch number.
    /// @param _chainId The ID of the chain.
    /// @param _batchNumber The batch number to check.
    /// @param _claimedSettlementLayer The settlement layer chain ID claimed in the proof.
    /// @param _claimedSettlementLayerBatchNumber The batch number on the settlement layer claimed in the proof.
    /// @return True if the claimed settlement layer is valid for this chain and batch.
    function isValidSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _claimedSettlementLayer,
        uint256 _claimedSettlementLayerBatchNumber
    ) external view returns (bool);
}
