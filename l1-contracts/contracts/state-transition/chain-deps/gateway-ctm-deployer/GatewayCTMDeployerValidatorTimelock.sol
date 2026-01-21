// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ValidatorTimelock} from "../../ValidatorTimelock.sol";

import {L2_BRIDGEHUB_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GatewayValidatorTimelockDeployerConfig, GatewayValidatorTimelockDeployerResult} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerValidatorTimelock
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM ValidatorTimelock deployer: deploys ValidatorTimelock.
/// @dev Deploys: ValidatorTimelock (implementation + proxy).
contract GatewayCTMDeployerValidatorTimelock {
    GatewayValidatorTimelockDeployerResult internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (GatewayValidatorTimelockDeployerResult memory result) {
        result = deployedResult;
    }

    constructor(GatewayValidatorTimelockDeployerConfig memory _config) {
        bytes32 salt = _config.salt;

        GatewayValidatorTimelockDeployerResult memory result;

        // Deploy ValidatorTimelock implementation
        result.validatorTimelockImplementation = address(new ValidatorTimelock{salt: salt}(L2_BRIDGEHUB_ADDR));

        // Deploy ValidatorTimelock proxy
        result.validatorTimelockProxy = address(
            new TransparentUpgradeableProxy{salt: salt}(
                result.validatorTimelockImplementation,
                _config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (_config.aliasedGovernanceAddress, 0))
            )
        );

        deployedResult = result;
    }
}
