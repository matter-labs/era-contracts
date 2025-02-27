// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2GatewaySpecificUpgrader} from "../common/interfaces/IL2GatewaySpecificUpgrader.sol";
import {IChainTypeManager, ChainCreationParams} from "../state-transition/IChainTypeManager.sol";
import {L2_FORCE_DEPLOYER_ADDR} from "../common/L2ContractAddresses.sol";
import {GATEWAY_CHAIN_ID} from "../common/Config.sol";
import {Unauthorized, InvalidProtocolVersion} from "../common/L1ContractErrors.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Contract used to perform Gateway-specific actions during upgrade.
 * @dev Should be deployed only on Gateway.
 */
contract L2GatewaySpecificUpgrader is IL2GatewaySpecificUpgrader {
    /// @notice Ensures that only the `FORCE_DEPLOYER` can call the function.
    /// @dev Note that it is vital to put this modifier at the start of *each* function,
    /// since even temporary anauthorized access can be dangerous.
    modifier onlyForceDeployer() {
        if (msg.sender != L2_FORCE_DEPLOYER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Executes an upgrade process if executed on Gateway chain.
    /// @dev This function allows only the `FORCE_DEPLOYER` to initiate the upgrade.
    /// If the delegate call fails, the function will revert the transaction, returning the error message
    /// provided by the delegated contract.
    function upgradeIfGateway(
        address ctmAddress,
        ChainCreationParams memory chainCreationParams,
        Diamond.DiamondCutData memory upgradeCutData,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion
    ) public payable onlyForceDeployer {
        if (block.chainid != GATEWAY_CHAIN_ID) return; // Do nothing

        IChainTypeManager(ctmAddress).setChainCreationParams(chainCreationParams);

        IChainTypeManager(ctmAddress).setNewVersionUpgrade(
            upgradeCutData,
            oldProtocolVersion,
            oldProtocolVersionDeadline,
            newProtocolVersion
        );
    }
}
