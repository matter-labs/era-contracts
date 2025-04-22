// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";
import {InvalidProtocolVersion, ZeroAddress, Unauthorized} from "../common/L1ContractErrors.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";

/// @title ServerNotifier contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract is designed to notify the server about migrations and protocol upgrade schedules.
contract ServerNotifier is Ownable2Step, ReentrancyGuard, Initializable {
    /// @dev Address of the ChainTypeManager smart contract.
    IChainTypeManager public chainTypeManager;

    /// @notice Emitted when a chain is migrated into the gateway.
    /// @param chainId The ID of the chain being migrated.
    event MigrateToGateway(uint256 indexed chainId);

    /// @notice Emitted when a chain is migrated out of the gateway.
    /// @param chainId The ID of the chain being migrated.
    event MigrateFromGateway(uint256 indexed chainId);

    /// @notice Emitted whenever an upgrade timestamp is set.
    /// @param chainId The ID of the chain.
    /// @param protocolVersion The protocol version being scheduled.
    /// @param upgradeTimestamp UNIX timestamp when the upgrade is expected.
    event UpgradeTimestampUpdated(uint256 indexed chainId, uint256 indexed protocolVersion, uint256 upgradeTimestamp);

    /// @notice Maps each chainId => protocolVersion => expected upgrade timestamp.
    mapping(uint256 chainId => mapping(uint256 protocolVersion => uint256 upgradeTimestamp))
        public protocolVersionToUpgradeTimestamp;

    /// @notice Checks if the caller is the admin of the chain.
    modifier onlyChainAdmin(uint256 _chainId) {
        if (msg.sender != chainTypeManager.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(bool disableInitializers) {
        if (disableInitializers) {
            _disableInitializers();
        }
    }

    /// @notice Used to initialize the contract
    /// @param _admin The owner of the contract
    function initialize(address _admin) external reentrancyGuardInitializer {
        if (_admin == address(0)) {
            revert ZeroAddress();
        }

        _transferOwnership(_admin);
    }

    /// @notice Sets a new chain type manager.
    /// @param _chainTypeManager The address of new chain type manager.
    function setChainTypeManager(IChainTypeManager _chainTypeManager) external onlyOwner {
        if (address(_chainTypeManager) == address(0)) {
            revert ZeroAddress();
        }
        chainTypeManager = IChainTypeManager(_chainTypeManager);
    }

    /// @notice Used to notify server of a chain migation to Gateway.
    /// @param _chainId The chainId of the ZKsync chain that is getting migrated.
    function migrateToGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        emit MigrateToGateway(_chainId);
    }

    /// @notice Used to notify server of a chain migation from Gateway.
    /// @param _chainId The chainId of the ZKsync chain that is getting migrated.
    function migrateFromGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        emit MigrateFromGateway(_chainId);
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
        require(chainTypeManager.protocolVersionIsActive(_protocolVersion), InvalidProtocolVersion());
        protocolVersionToUpgradeTimestamp[_chainId][_protocolVersion] = _upgradeTimestamp;
        emit UpgradeTimestampUpdated(_chainId, _protocolVersion, _upgradeTimestamp);
    }
}
