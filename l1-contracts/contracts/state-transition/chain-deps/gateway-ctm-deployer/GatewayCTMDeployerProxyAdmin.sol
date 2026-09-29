// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {GatewayProxyAdminDeployerConfig, GatewayProxyAdminDeployerResult} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerProxyAdmin
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM ProxyAdmin deployer: deploys ProxyAdmin.
/// @dev Deploys: ProxyAdmin and transfers ownership to governance.
contract GatewayCTMDeployerProxyAdmin {
    GatewayProxyAdminDeployerResult internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (GatewayProxyAdminDeployerResult memory result) {
        result = deployedResult;
    }

    constructor(GatewayProxyAdminDeployerConfig memory _config) {
        bytes32 salt = _config.salt;

        GatewayProxyAdminDeployerResult memory result;

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin{salt: salt}();
        // Note, that the governance still has to accept it.
        // It will happen in a separate voting after the deployment is done.
        proxyAdmin.transferOwnership(_config.aliasedGovernanceAddress);
        result.chainTypeManagerProxyAdmin = address(proxyAdmin);

        deployedResult = result;
    }
}
