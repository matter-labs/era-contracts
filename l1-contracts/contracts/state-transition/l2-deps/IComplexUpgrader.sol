// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IComplexUpgrader {
    /// @notice Executes an upgrade process by delegating calls to another contract.
    /// @dev Compatible with Era only.
    /// @param _forceDeployments the list of initial deployments that should be performed before the upgrade.
    /// They would typically, though not necessarily include the deployment of the upgrade implementation itself.
    /// @param _delegateTo the address of the contract to which the calls will be delegated
    /// @param _calldata the calldata to be delegate called in the `_delegateTo` contract
    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
