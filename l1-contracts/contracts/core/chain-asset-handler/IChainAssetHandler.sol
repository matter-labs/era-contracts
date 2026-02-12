// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

/// @notice Tracks migration batch numbers for a chain that migrated to a settlement layer and back.
/// @param migrateToGWBatchNumber The last batch executed on L1 before migrating TO the gateway.
/// @param migrateFromGWBatchNumber The last batch executed on Gateway before migrating back to L1.
/// @param settlementLayerChainId The chain ID of the settlement layer where the chain settled during the time period.
/// @param isActive Whether the chain is actively settling on the settlement layer right now.
struct MigrationInterval {
    uint256 migrateToGWBatchNumber;
    uint256 migrateFromGWBatchNumber;
    uint256 settlementLayerChainId;
    bool isActive;
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

    /// @dev Denotes whether the migrations of chains is paused.
    function migrationPaused() external view returns (bool);

    /// @notice Pauses migration functions.
    function pauseMigration() external;

    /// @notice Unpauses migration functions.
    function unpauseMigration() external;
}
