// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

/// @notice Tracks migration batch numbers for a chain that migrated to a settlement layer and back.
/// @param migrateToSLBatchNumber The last batch executed on L1 before migrating TO the settlement layer.
/// @param migrateFromSLBatchNumber The last batch executed on SL before migrating back to L1.
/// @param settlementLayerChainId The chain ID of the settlement layer where migration happened.
/// @param isSet Whether this migration interval has been set (to distinguish from uninitialized state).
struct MigrationInterval {
    uint256 migrateToSLBatchNumber;
    uint256 migrateFromSLBatchNumber;
    uint256 settlementLayerChainId;
    bool isSet;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAssetHandler is IAssetHandler {
    /// @notice Emitted when the bridging to the chain is started.
    /// @param chainId Chain ID of the ZK chain
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param settlementLayerChainId The chain id of the settlement layer the chain migrates to.
    event MigrationStarted(uint256 indexed chainId, bytes32 indexed assetId, uint256 indexed settlementLayerChainId);

    /// @notice Emitted when the bridging to the chain is complete.
    /// @param chainId Chain ID of the ZK chain
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param zkChain The address of the ZK chain on the chain where it is migrated to.
    event MigrationFinalized(uint256 indexed chainId, bytes32 indexed assetId, address indexed zkChain);

    function migrationNumber(uint256 _chainId) external view returns (uint256);

    function setMigrationNumberForV31(uint256 _chainId) external;

    /// @notice Returns the legacy Gateway chain ID used for settlement layer validation.
    // solhint-disable-next-line func-name-mixedcase
    function LEGACY_GW_CHAIN_ID() external view returns (uint256);

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
    /// @return True if the claimed settlement layer is valid for this chain and batch.
    function isValidSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _claimedSettlementLayer
    ) external view returns (bool);

    /// @dev Denotes whether the migrations of chains is paused.
    function migrationPaused() external view returns (bool);

    /// @notice Pauses migration functions.
    function pauseMigration() external;

    /// @notice Unpauses migration functions.
    function unpauseMigration() external;
}
