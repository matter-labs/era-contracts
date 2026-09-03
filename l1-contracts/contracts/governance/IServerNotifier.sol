// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {IUpgradePreconditionChecker} from "../upgrades/IUpgradePreconditionChecker.sol";

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

    /// @notice Emitted whenever the precondition checker registered for a protocol version changes.
    /// @param protocolVersion The old protocol version the checker guards scheduling from.
    /// @param checker The registered checker; zero when deregistered.
    event UpgradePreconditionCheckerSet(uint256 indexed protocolVersion, address checker);

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

    /// @notice Returns the precondition checker consulted when scheduling an upgrade away from a
    /// protocol version; zero when that version has no extra scheduling checks.
    /// @param _oldProtocolVersion The protocol version chains upgrade *from*.
    function upgradePreconditionChecker(
        uint256 _oldProtocolVersion
    ) external view returns (IUpgradePreconditionChecker);

    /// @notice Registers (or, with the zero address, deregisters) the precondition checker for a
    /// protocol version; see {protocol-docs/upgrade-scheduling.md}.
    /// @param _oldProtocolVersion The protocol version chains upgrade *from*.
    /// @param _checker The checker to consult in `setUpgradeTimestamp`; zero to deregister.
    function setUpgradePreconditionChecker(uint256 _oldProtocolVersion, IUpgradePreconditionChecker _checker) external;

    /// @notice Non-reverting mirror of `setUpgradeTimestamp`'s upgrade-cut and precondition
    /// checks, for operators and CI. It does not cover the caller/timestamp validation, so an
    /// empty result means the preconditions hold — not that any call will succeed.
    /// @param _chainId The ID of the chain to dry-run scheduling for.
    /// @return failed The error selectors of the failed checks; empty when the checks pass.
    function previewUpgradePreconditions(uint256 _chainId) external view returns (bytes4[] memory failed);
}
