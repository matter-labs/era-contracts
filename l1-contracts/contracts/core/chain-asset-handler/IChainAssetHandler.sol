// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

/// @notice Tracks migration batch numbers for a chain that migrated to a settlement layer and back.
/// @param migrateToGWBatchNumber The last batch executed on L1 before migrating TO the settlement layer.
/// @param migrateFromGWBatchNumber The last batch executed on the settlement layer before migrating back to L1.
/// @param settlementLayerBatchLowerBound The lower bound for the settlement layer's batch number at the time the chain
/// migrated TO the settlement layer. The chain's data will only start appearing in settlement layer batches at or after this point.
/// @param settlementLayerBatchUpperBound The upper bound for the settlement layer's batch number at the time the chain
/// migrated FROM the settlement layer. This is not a perfect bound — the exact settlement layer batch number is not
/// trivially available, so we record the settlement layer's current batch number when `bridgeMint` is called on L1 to
/// finalize the return migration. The sooner the migration is finalized, the more precise this value is, since the
/// settlement layer continues producing batches in the meantime. A more precise solution will be introduced in future releases.
/// @param settlementLayerChainId The chain ID of the settlement layer where the chain settled during the time period.
/// @param isActive Whether the chain is actively settling on the settlement layer right now.
struct MigrationInterval {
    uint256 migrateToGWBatchNumber;
    uint256 migrateFromGWBatchNumber;
    uint256 settlementLayerBatchLowerBound;
    uint256 settlementLayerBatchUpperBound;
    uint256 settlementLayerChainId;
    bool isActive;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAssetHandlerBase is IAssetHandler {
    /// @notice Emitted when the bridging to the chain is started.
    /// @param chainId Chain ID of the ZK chain
    /// @param migrationNumber The migration number for this migration.
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param settlementLayerChainId The chain id of the settlement layer the chain migrates to.
    event MigrationStarted(
        uint256 indexed chainId,
        uint256 migrationNumber,
        bytes32 indexed assetId,
        uint256 indexed settlementLayerChainId
    );

    /// @notice Emitted when the bridging to the chain is complete.
    /// @param chainId Chain ID of the ZK chain
    /// @param migrationNumber The migration number for this migration.
    /// @param assetId Asset ID of the token for the zkChain's CTM
    /// @param zkChain The address of the ZK chain on the chain where it is migrated to.
    event MigrationFinalized(
        uint256 indexed chainId,
        uint256 migrationNumber,
        bytes32 indexed assetId,
        address indexed zkChain
    );

    /// @notice Emitted when migration related fns are paused.
    /// @param pauser Address that triggered the pause
    event PausedMigration(address indexed pauser);

    /// @notice Emitted when migration related fns are unpaused.
    /// @param pauser Address that triggered the unpause
    event UnpausedMigration(address indexed pauser);

    function migrationNumber(uint256 _chainId) external view returns (uint256);

    /// @dev Denotes whether the migrations of chains is paused.
    function migrationPaused() external view returns (bool);

    /// @notice Pauses migration functions.
    function pauseMigration() external;

    /// @notice Unpauses migration functions.
    function unpauseMigration() external;
}
