// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";

interface IL2GatewayUpgrade {
    function upgrade(
        IL2ContractDeployer.ForceDeployment[] calldata _forceDeployments,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable;
}
