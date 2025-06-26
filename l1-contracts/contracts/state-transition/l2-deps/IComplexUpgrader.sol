// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IComplexUpgrader {
    struct ZKsyncOSForceDeploymentInfo {
        bytes deployedBytecodeInfo;
        address newAddress;
    }

    function forceDeployAndUpgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function forceDeployAndUpgradeZKOS(
        ZKsyncOSForceDeploymentInfo[] calldata _forceDeployments,
        address _delegateTo,
        bytes calldata _calldata
    ) external payable;

    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
