// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

/// @notice Tracks migration batch numbers for a chain that migrated to a settlement layer and back.
/// @param migrateToSLBatchNumber The last batch executed on L1 before migrating TO the settlement layer.
/// @param migrateFromSLBatchNumber The last batch executed on SL before migrating back to L1.
/// @param settlementLayerChainId The chain ID of the settlement layer where migration happened.
struct MigrationInterval {
    uint256 migrateToSLBatchNumber;
    uint256 migrateFromSLBatchNumber;
    uint256 settlementLayerChainId;
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

    /// @notice Returns the first batch number in the legacy GW range.
    // solhint-disable-next-line func-name-mixedcase
    function LEGACY_GW_BATCH_FROM() external view returns (uint256);

    /// @notice Returns the last batch number in the legacy GW range.
    // solhint-disable-next-line func-name-mixedcase
    function LEGACY_GW_BATCH_TO() external view returns (uint256);

    /// @notice Returns the migration interval for a chain.
    /// @param _chainId The ID of the chain.
    /// @return migrateToSLBatchNumber The last batch executed on L1 before migrating TO settlement layer.
    /// @return migrateFromSLBatchNumber The last batch executed on SL before migrating back to L1.
    /// @return settlementLayerChainId The chain ID of the settlement layer.
    function migrationInterval(
        uint256 _chainId
    )
        external
        view
        returns (uint256 migrateToSLBatchNumber, uint256 migrateFromSLBatchNumber, uint256 settlementLayerChainId);

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
