// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2GatewaySpecificUpgrader} from "./interfaces/IL2GatewaySpecificUpgrader.sol";
import {ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {FORCE_DEPLOYER, DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";
import {GATEWAY_CHAIN_ID} from "./Constants.sol";
import {Unauthorized} from "./SystemContractErrors.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";

import {IChainTypeManager, ChainCreationParams, DiamondCutData} from "./interfaces/IChainTypeManager.sol";

interface IOwnable {
    function owner() external view returns (address);
}

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
        if (msg.sender != FORCE_DEPLOYER) {
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
        ChainCreationParams calldata chainCreationParams,
        DiamondCutData calldata upgradeCutData,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion,
        ForceDeployment[] calldata additionalForceDeployments
    ) public onlyForceDeployer {
        if (block.chainid != GATEWAY_CHAIN_ID) return; // Do nothing

        address ctmOwner = IOwnable(ctmAddress).owner();

        bytes memory setChainCreationParamsCall = abi.encodeCall(
            IChainTypeManager.setChainCreationParams,
            (chainCreationParams)
        );
        SystemContractHelper.mimicCallWithPropagatedRevert(ctmAddress, ctmOwner, setChainCreationParamsCall);

        bytes memory setNewVersionUpgradeCall = abi.encodeCall(
            IChainTypeManager.setNewVersionUpgrade,
            (upgradeCutData, oldProtocolVersion, oldProtocolVersionDeadline, newProtocolVersion)
        );
        SystemContractHelper.mimicCallWithPropagatedRevert(ctmAddress, ctmOwner, setNewVersionUpgradeCall);

        DEPLOYER_SYSTEM_CONTRACT.forceDeployOnAddresses(additionalForceDeployments);
    }
}
