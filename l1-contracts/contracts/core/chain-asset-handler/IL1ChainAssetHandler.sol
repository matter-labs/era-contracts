// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MigrationInterval} from "./IChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1ChainAssetHandler {
    function isMigrationInProgress(uint256 _chainId) external view returns (bool);

    /// @notice Whether a chain meets the preconditions to migrate from L1 to a settlement layer.
    /// See {protocol-docs/chain-lifecycle.md#role}.
    /// @param _chainId The chain id to check.
    function isReadyForMigration(uint256 _chainId) external view returns (bool);

    /// @notice Requests that deposits be paused on the settlement layer for a migrating chain.
    /// @dev Callable only by the chain's diamond. Forwards the request to the settlement layer's
    /// `L2ChainAssetHandler` as a service transaction.
    /// @param _chainId The chain whose deposits should be paused on the settlement layer.
    function requestPauseDepositsForChainOnGateway(uint256 _chainId) external;

    /// @notice Returns the migration interval for a chain at a specific migration number.
    /// @param _chainId The ID of the chain.
    /// @param _migrationNumber The migration number that opened the interval (`MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER`).
    /// @return interval The migration interval data.
    function migrationInterval(
        uint256 _chainId,
        uint256 _migrationNumber
    ) external view returns (MigrationInterval memory interval);

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
