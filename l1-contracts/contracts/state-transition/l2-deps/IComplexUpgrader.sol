// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IComplexUpgrader {
    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
