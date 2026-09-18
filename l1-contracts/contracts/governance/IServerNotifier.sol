// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {DisabledProofSystems} from "../common/Config.sol";

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

    /// @notice Emitted to notify the server before the chain admin changes which proof systems the chain requires.
    /// @param chainId The ID of the chain.
    /// @param disabledProofSystems The proof systems the chain admin is going to disable with `setProofSystemStatus`.
    event ProofSystemStatusNotified(uint256 indexed chainId, DisabledProofSystems disabledProofSystems);

    /// @notice Returns the upgrade timestamp for a specific chain ID and protocol version.
    /// @param _chainId The ID of the chain to query.
    /// @param _oldProtocolVersion The protocol version to query.
    /// @return The timestamp at which the upgrade is expected.
    function protocolVersionToUpgradeTimestamp(
        uint256 _chainId,
        uint256 _oldProtocolVersion
    ) external view returns (uint256);

    function setChainTypeManager(IChainTypeManager _chainTypeManager) external;

    function migrateToGateway(uint256 _chainId) external;

    function migrateFromGateway(uint256 _chainId) external;

    function setUpgradeTimestamp(uint256 _chainId, uint256 _upgradeTimestamp) external;

    function notifyProofSystemStatus(uint256 _chainId, DisabledProofSystems calldata _disabledProofSystems) external;
}
