// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IComplexUpgrader} from "./interfaces/IComplexUpgrader.sol";
import {ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {FORCE_DEPLOYER, DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";
import {Unauthorized, AddressHasNoCode} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Upgrader which should be used to perform complex multistep upgrades on L2. In case some custom logic for an upgrade is needed
 * this logic should be deployed into the user space and then this contract will delegatecall to the deployed contract.
 */
contract ComplexUpgrader is IComplexUpgrader {
    /// @notice Ensures that only the `FORCE_DEPLOYER` can call the function.
    /// @dev Note that it is vital to put this modifier at the start of *each* function,
    /// since even temporary anauthorized access can be dangerous.
    modifier onlyForceDeployer() {
        // Note, that it is not
        if (msg.sender != FORCE_DEPLOYER) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev This function allows only the `FORCE_DEPLOYER` to initiate the upgrade.
    /// If the delegate call fails, the function will revert the transaction, returning the error message
    /// provided by the delegated contract.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgrade(
        ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable override onlyForceDeployer {
        DEPLOYER_SYSTEM_CONTRACT.forceDeployOnAddresses(_forceDeployments);

        upgrade(_delegateTo, _calldata);
    }

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev This function allows only the `FORCE_DEPLOYER` to initiate the upgrade.
    /// If the delegate call fails, the function will revert the transaction, returning the error message
    /// provided by the delegated contract.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function upgrade(address _delegateTo, bytes calldata _calldata) public payable onlyForceDeployer {
        if (_delegateTo.code.length == 0) {
            revert AddressHasNoCode(_delegateTo);
        }
        (bool success, bytes memory returnData) = _delegateTo.delegatecall(_calldata);
        assembly {
            if iszero(success) {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
