// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

/// @notice Tracks migration batch numbers for a chain that migrated to a settlement layer and back.
/// @param migrateToGWBatchNumber The last batch executed on L1 before migrating TO the settlement layer.
/// @param migrateFromGWBatchNumber The last batch executed on the settlement layer before migrating back to L1.
/// @param settlementLayerBatchLowerBound The lower bound for the settlement layer's batch number at the time the chain
/// migrated TO the settlement layer. The chain's data will only start appearing in settlement layer batches at or after this point.
/// @param settlementLayerBatchUpperBound The upper bound for the settlement layer's batch number at the time the chain
/// migrated FROM the settlement layer. Imprecise: recorded as the settlement layer's current batch number when
/// `bridgeMint` finalizes the return migration on L1, so the later that happens, the looser the bound.
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

    /// @notice Emitted when an upgrade pauser is registered or removed by the owner.
    event UpgradePauserSet(address indexed pauser, bool allowed);

    /// @notice Emitted when an upgrade pauser takes its hold on the migration pause.
    event MigrationPauseAcquired(address indexed pauser);

    /// @notice Emitted when an upgrade pauser's hold is released (by itself or by the owner).
    event MigrationPauseReleased(address indexed pauser);

    function migrationNumber(uint256 _chainId) external view returns (uint256);

    /// @notice Whether chain migrations are paused: the owner's pause OR at least one upgrade
    ///         pauser's hold.
    function migrationPaused() external view returns (bool);

    /// @notice Whether `_pauser` may hold migrations paused during an upgrade lifecycle.
    function isUpgradePauser(address _pauser) external view returns (bool);

    /// @notice Whether `_pauser` currently holds migrations paused.
    function upgradePauseHeld(address _pauser) external view returns (bool);

    /// @notice The number of upgrade holds currently in place.
    function upgradePauseHolds() external view returns (uint256);

    /// @notice Registers or removes an upgrade pauser. Owner only.
    function setUpgradePauser(address _pauser, bool _allowed) external;

    /// @notice Takes the caller's hold on the migration pause. Registered pausers only; one hold
    ///         per pauser.
    function acquireMigrationPause() external;

    /// @notice Releases the caller's own hold — never another pauser's, never the owner's pause.
    function releaseMigrationPause() external;

    /// @notice Owner recovery: releases `_pauser`'s hold (a stuck or retired executor).
    function clearMigrationPauseHold(address _pauser) external;

    /// @notice Whether chain migrations between settlement layers are enabled in the current release.
    /// @dev Chain migrations are explicitly disabled in the v32 release, in which all chains are
    /// required to settle on L1. See `CHAIN_MIGRATIONS_ENABLED` in `Config.sol`.
    function migrationsEnabled() external view returns (bool);

    /// @notice Sets the owner's migration pause.
    function pauseMigration() external;

    /// @notice Clears the owner's migration pause (upgrade holds are unaffected).
    function unpauseMigration() external;
}
