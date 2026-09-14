// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSVerifierPlonk} from "../../verifiers/ZKsyncOSVerifierPlonk.sol";
import {ZKsyncOSVerifier} from "../../verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "../../verifiers/ZKsyncOSTestnetVerifier.sol";

import {IVerifier} from "../../chain-interfaces/IVerifier.sol";

import {Verifiers} from "contracts/common/StateTransitionTypes.sol";
import {GatewayVerifiersDeployerConfig} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerVerifiers
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM ZKsyncOS Verifiers deployer: deploys ZKsyncOS verifier contracts.
/// @dev Deploys ZKsyncOSVerifierPlonk and the ZKsync OS main/testnet verifier.
/// This contract is expected to be deployed via the built-in L2 `Create2Factory`.
contract GatewayCTMDeployerVerifiers {
    Verifiers internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (Verifiers memory result) {
        result = deployedResult;
    }

    constructor(GatewayVerifiersDeployerConfig memory _config) {
        bytes32 salt = _config.salt;

        Verifiers memory result;

        // Deploy ZKsyncOS verifiers
        result.verifierPlonk = address(new ZKsyncOSVerifierPlonk{salt: salt}());

        // Deploy main verifier
        if (_config.testnetVerifier) {
            result.verifier = address(new ZKsyncOSTestnetVerifier{salt: salt}(IVerifier(result.verifierPlonk)));
        } else {
            result.verifier = address(new ZKsyncOSVerifier{salt: salt}(IVerifier(result.verifierPlonk)));
        }

        deployedResult = result;
    }
}
