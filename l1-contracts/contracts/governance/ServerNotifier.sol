// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";
import {InvalidProtocolVersion, Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandler} from "../core/chain-asset-handler/IChainAssetHandler.sol";

/// @title ServerNotifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract enables chain admins to emit migration events for the server.
/// @dev The `owner` of this contract is expected to be the admin of the chainTypeManager contract.
contract ServerNotifier is Ownable2Step, ReentrancyGuard, Initializable {
    /// @notice The chainTypeManager, which is used to retrieve chain administrator addresses.
    IChainTypeManager public chainTypeManager;

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

    /// @notice Maps each chainId => protocolVersion => expected upgrade timestamp.
    mapping(uint256 chainId => mapping(uint256 protocolVersion => uint256 upgradeTimestamp))
        public protocolVersionToUpgradeTimestamp;

    /// @notice Modifier to ensure the caller is the administrator of the specified chain.
    /// @param _chainId The ID of the chain that requires the caller to be an admin.
    modifier onlyChainAdmin(uint256 _chainId) {
        if (msg.sender != chainTypeManager.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Initialize the implementation to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract by setting the initial owner.
    /// @param _initialOwner The address that will be set as the contract owner.
    function initialize(address _initialOwner) public reentrancyGuardInitializer {
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Sets the chainTypeManager contract which is responsible for providing chain administrator information.
    /// @param _chainTypeManager The address of the chainTypeManager contract.
    /// @dev Callable only by the current owner.
    function setChainTypeManager(IChainTypeManager _chainTypeManager) external onlyOwner {
        if (address(_chainTypeManager) == address(0)) {
            revert ZeroAddress();
        }
        chainTypeManager = IChainTypeManager(_chainTypeManager);
    }

    /// @notice Emits an event to signal that the chain is migrating to a gateway.
    /// @param _chainId The identifier of the chain that is migrating.
    /// @dev Restricted to the chain administrator.
    function migrateToGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        uint256 migrationNumber = _getMigrationNumber(_chainId);
        emit MigrateToGateway(_chainId, migrationNumber);
    }

    /// @notice Emits an event to signal that the chain is migrating from a gateway.
    /// @param _chainId The identifier of the chain that is migrating.
    /// @dev Restricted to the chain administrator.
    function migrateFromGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        uint256 migrationNumber = _getMigrationNumber(_chainId);
        emit MigrateFromGateway(_chainId, migrationNumber);
    }

    /// @notice Gets the migration number for a chain from the ChainAssetHandler.
    /// @param _chainId The identifier of the chain.
    /// @return The current migration number for the chain.
    function _getMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        address bridgehub = chainTypeManager.BRIDGE_HUB();
        address chainAssetHandler = IBridgehubBase(bridgehub).chainAssetHandler();
        return IChainAssetHandler(chainAssetHandler).migrationNumber(_chainId);
    }

    /// @notice Set the expected upgrade timestamp for a specific protocol version. Only allowed to be called by ChainAdmin.
    /// @param _chainId The chainId of the ZKsync chain for which the upgrade timestamp is being set.
    /// @param _protocolVersion The ZKsync chain protocol version.
    /// @param _upgradeTimestamp The timestamp at which the chain node should expect the upgrade to happen.
    function setUpgradeTimestamp(
        uint256 _chainId,
        uint256 _protocolVersion,
        uint256 _upgradeTimestamp
    ) external onlyChainAdmin(_chainId) {
        if (!chainTypeManager.protocolVersionIsActive(_protocolVersion)) {
            revert InvalidProtocolVersion();
        }
        protocolVersionToUpgradeTimestamp[_chainId][_protocolVersion] = _upgradeTimestamp;
        emit UpgradeTimestampUpdated(_chainId, _protocolVersion, _upgradeTimestamp);
    }
}
