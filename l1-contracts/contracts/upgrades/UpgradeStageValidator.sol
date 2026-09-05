// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {
    MigrationPaused,
    MigrationsNotPaused,
    ProtocolIdMismatch,
    UpgradePreconditionCheckerMismatch,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {IChainAssetHandlerBase} from "../core/chain-asset-handler/IChainAssetHandler.sol";
import {IServerNotifier} from "../governance/IServerNotifier.sol";
import {IUpgradePreconditionChecker} from "./IUpgradePreconditionChecker.sol";

/// @title Rules to validate that different upgrade stages have passed.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract will be used by the governance to ensure that certain criteria are met before proceeding to the
/// next upgrade stage.
contract UpgradeStageValidator {
    /// @notice Address of bridgehub.
    IL1Bridgehub public immutable BRIDGEHUB;

    /// @notice Address of chain type manager.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice Protocol Version of chain after the upgrade
    uint256 public immutable NEW_PROTOCOL_VERSION;

    /// @dev Initializes the contract with immutable values for `BRIDGEHUB`, `CHAIN_TYPE_MANAGER`,
    /// and `NEW_PROTOCOL_VERSION`.
    /// @param _chainTypeManager The address of the ChainTypeManager for the chain.
    /// @param _newProtocolVersion The protocol version of the chain post upgrade.
    constructor(address _chainTypeManager, uint256 _newProtocolVersion) {
        if (_chainTypeManager == address(0)) {
            revert ZeroAddress();
        }

        CHAIN_TYPE_MANAGER = IChainTypeManager(_chainTypeManager);
        BRIDGEHUB = IL1Bridgehub(CHAIN_TYPE_MANAGER.BRIDGE_HUB());
        NEW_PROTOCOL_VERSION = _newProtocolVersion;
    }

    /// @notice Check if migrations are paused
    function checkMigrationsPaused() external view {
        if (!IChainAssetHandlerBase(BRIDGEHUB.chainAssetHandler()).migrationPaused()) {
            revert MigrationsNotPaused();
        }
    }

    /// @notice Check if migrations are unpaused
    function checkMigrationsUnpaused() external view {
        if (IChainAssetHandlerBase(BRIDGEHUB.chainAssetHandler()).migrationPaused()) {
            revert MigrationPaused();
        }
    }

    /// @notice Check if the upgrade data was sent to the CTM.
    function checkProtocolUpgradePresence() external view {
        uint256 protocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();

        if (protocolVersion != NEW_PROTOCOL_VERSION) {
            revert ProtocolIdMismatch(NEW_PROTOCOL_VERSION, protocolVersion);
        }
    }

    /// @notice Check that the expected upgrade precondition checker is registered.
    /// @param _oldProtocolVersion The protocol version the checker guards.
    /// @param _expectedChecker The checker expected for the protocol version.
    function checkUpgradePreconditionChecker(
        uint256 _oldProtocolVersion,
        IUpgradePreconditionChecker _expectedChecker
    ) external view {
        IUpgradePreconditionChecker actualChecker = IServerNotifier(CHAIN_TYPE_MANAGER.serverNotifierAddress())
            .upgradePreconditionChecker(_oldProtocolVersion);

        if (actualChecker != _expectedChecker) {
            revert UpgradePreconditionCheckerMismatch(address(_expectedChecker), address(actualChecker));
        }
    }
}
