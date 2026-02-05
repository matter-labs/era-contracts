// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSVerifierFflonk} from "../../verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "../../verifiers/ZKsyncOSVerifierPlonk.sol";
import {ZKsyncOSDualVerifier} from "../../verifiers/ZKsyncOSDualVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "../../verifiers/ZKsyncOSTestnetVerifier.sol";

import {IVerifier} from "../../chain-interfaces/IVerifier.sol";

import {WrongCTMDeployerVariant} from "../../../common/L1ContractErrors.sol";

import {GatewayVerifiersDeployerConfig, Verifiers} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerVerifiersZKsyncOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM ZKsyncOS Verifiers deployer: deploys ZKsyncOS verifier contracts.
/// @dev Deploys: ZKsyncOSVerifierFflonk, ZKsyncOSVerifierPlonk, and ZKsyncOS DualVerifier/TestnetVerifier.
/// For Era verifiers, use GatewayCTMDeployerVerifiers instead.
/// This contract is expected to be deployed via the built-in L2 `Create2Factory`.
contract GatewayCTMDeployerVerifiersZKsyncOS {
    Verifiers internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (Verifiers memory result) {
        result = deployedResult;
    }

    constructor(GatewayVerifiersDeployerConfig memory _config) {
        if (!_config.isZKsyncOS) {
            revert WrongCTMDeployerVariant();
        }
        bytes32 salt = _config.salt;

        Verifiers memory result;

        // Deploy ZKsyncOS verifiers
        result.verifierFflonk = address(new ZKsyncOSVerifierFflonk{salt: salt}());
        result.verifierPlonk = address(new ZKsyncOSVerifierPlonk{salt: salt}());

        // Deploy main verifier
        if (_config.testnetVerifier) {
            result.verifier = address(
                new ZKsyncOSTestnetVerifier{salt: salt}(
                    IVerifier(result.verifierPlonk),
                    _config.aliasedGovernanceAddress
                )
            );
        } else {
            result.verifier = address(
                new ZKsyncOSDualVerifier{salt: salt}(IVerifier(result.verifierPlonk), _config.aliasedGovernanceAddress)
            );
        }

        deployedResult = result;
    }
}
