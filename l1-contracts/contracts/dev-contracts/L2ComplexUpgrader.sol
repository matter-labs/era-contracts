// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {AddressHasNoCode, Unauthorized} from "../common/L1ContractErrors.sol";

import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Upgrader which should be used to perform complex multistep upgrades on L2. In case some custom logic for an upgrade is needed
 * this logic should be deployed into the user space and then this contract will delegatecall to the deployed contract.
 */
contract L2ComplexUpgrader is IComplexUpgrader {
    /// @notice Ensures that only the `FORCE_DEPLOYER` can call the function.
    /// @dev Note that it is vital to put this modifier at the start of *each* function,
    /// since even temporary unauthorized access can be dangerous.
    modifier onlyForceDeployer() {
        if (msg.sender != L2_FORCE_DEPLOYER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev This function allows only the `FORCE_DEPLOYER` to initiate the upgrade.
    /// If the delegate call fails, the function will revert the transaction, returning the error message
    /// provided by the delegated contract.
    /// @dev Compatible with Era only.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable onlyForceDeployer {
        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(_forceDeployments);

        upgrade(_delegateTo, _calldata);
    }

    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev Similar to `forceDeployAndUpgrade`, but allows for universal force deployments, that
    /// work for both ZKsyncOS and Era.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgradeUniversal(
        UniversalContractUpgradeInfo[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable onlyForceDeployer {
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _forceDeployments.length; ++i) {
            L2GenesisForceDeploymentsHelper.conductContractUpgrade(
                _forceDeployments[i].upgradeType,
                _forceDeployments[i].deployedBytecodeInfo,
                _forceDeployments[i].newAddress
            );
        }

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
        // slither-disable-next-line controlled-delegatecall
        (bool success, bytes memory returnData) = _delegateTo.delegatecall(_calldata);
        assembly {
            if iszero(success) {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
