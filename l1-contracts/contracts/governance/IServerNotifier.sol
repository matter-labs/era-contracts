// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";

/// @title IServerNotifier
/// @notice Events and external API for ServerNotifier.
interface IServerNotifier {
    /// @notice Emitted to notify the server before a chain migrates to the ZK gateway.
    /// @param chainId The identifier for the chain initiating migration to the ZK gateway.
    /// @param migrationNumber The migration number for this migration.
    event MigrateToGateway(uint256 indexed chainId, uint256 migrationNumber);

    /// @notice Emitted to notify the server before a chain migrates from the ZK gateway.
    /// @param chainId The identifier for the chain initiating migration from the ZK gateway.
    /// @param migrationNumber The migration number for this migration.
    event MigrateFromGateway(uint256 indexed chainId, uint256 migrationNumber);

    /// @notice Emitted whenever an upgrade timestamp is set.
    /// @param chainId The ID of the chain where the upgrade is scheduled.
    /// @param protocolVersion The protocol version being scheduled.
    /// @param upgradeTimestamp UNIX timestamp when the upgrade is expected.
    event UpgradeTimestampUpdated(uint256 indexed chainId, uint256 indexed protocolVersion, uint256 upgradeTimestamp);

    function setChainTypeManager(IChainTypeManager _chainTypeManager) external;

    function migrateToGateway(uint256 _chainId) external;

    function migrateFromGateway(uint256 _chainId) external;

    function setUpgradeTimestamp(uint256 _chainId, uint256 _protocolVersion, uint256 _upgradeTimestamp) external;
}
