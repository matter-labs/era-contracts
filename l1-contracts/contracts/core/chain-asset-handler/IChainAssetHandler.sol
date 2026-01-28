// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetHandler} from "../../bridge/interfaces/IAssetHandler.sol";

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

    /// @dev Denotes whether the migrations of chains is paused.
    function migrationPaused() external view returns (bool);

    /// @notice Pauses migration functions.
    function pauseMigration() external;

    /// @notice Unpauses migration functions.
    function unpauseMigration() external;
}
