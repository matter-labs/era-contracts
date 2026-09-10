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

    /// @notice Emitted when a CTM's own migrations are paused by that CTM's owner.
    event PausedCTMMigration(address indexed ctm, address indexed pauser);

    /// @notice Emitted when a CTM's own migrations are unpaused by that CTM's owner.
    event UnpausedCTMMigration(address indexed ctm, address indexed pauser);

    function migrationNumber(uint256 _chainId) external view returns (uint256);

    /// @notice Whether the ECOSYSTEM-wide migration pause is set.
    /// @dev Not the whole answer for a given chain: its CTM may be paused on its own. Callers
    ///      deciding whether a migration can proceed want {migrationPausedFor}.
    function migrationPaused() external view returns (bool);

    /// @notice Whether migrations are paused for chains under `_ctm` — the ecosystem-wide pause
    ///         OR that CTM's own.
    function migrationPausedFor(address _ctm) external view returns (bool);

    /// @notice Whether `_ctm`'s own migration pause is set.
    function ctmMigrationPaused(address _ctm) external view returns (bool);

    /// @notice Whether chain migrations between settlement layers are enabled in the current release.
    /// @dev Chain migrations are explicitly disabled in the v32 release, in which all chains are
    /// required to settle on L1. See `CHAIN_MIGRATIONS_ENABLED` in `Config.sol`.
    function migrationsEnabled() external view returns (bool);

    /// @notice Pauses chain migrations ecosystem-wide, for every CTM. Owner only.
    /// @dev Incident control. A CTM upgrading itself uses {pauseCTMMigration} so it does not stop
    ///      chains under other CTMs, and cannot lift an incident pause.
    function pauseMigration() external;

    /// @notice Lifts the ecosystem-wide pause. Owner only. CTM-level pauses are unaffected.
    function unpauseMigration() external;

    /// @notice Pauses migrations for chains under `_ctm`. Callable only by `_ctm`'s current
    ///         owner — during an upgrade, its bound `CTMUpgradeExecutor`.
    function pauseCTMMigration(address _ctm) external;

    /// @notice Lifts `_ctm`'s own pause. Callable only by `_ctm`'s current owner, and it cannot
    ///         lift the ecosystem-wide pause or another CTM's.
    function unpauseCTMMigration(address _ctm) external;
}
