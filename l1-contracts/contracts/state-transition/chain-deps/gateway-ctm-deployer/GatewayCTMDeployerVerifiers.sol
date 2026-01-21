// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraVerifierFflonk} from "../../verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "../../verifiers/EraVerifierPlonk.sol";
import {EraDualVerifier} from "../../verifiers/EraDualVerifier.sol";
import {EraTestnetVerifier} from "../../verifiers/EraTestnetVerifier.sol";

import {IVerifier} from "../../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../../chain-interfaces/IVerifierV2.sol";

import {WrongCTMDeployerVariant} from "../../../common/L1ContractErrors.sol";

import {GatewayVerifiersDeployerConfig, Verifiers} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerVerifiers
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM Era Verifiers deployer: deploys Era verifier contracts.
/// @dev Deploys: EraVerifierFflonk, EraVerifierPlonk, and Era DualVerifier/TestnetVerifier.
/// For ZKsyncOS verifiers, use GatewayCTMDeployerVerifiersZKsyncOS instead.
contract GatewayCTMDeployerVerifiers {
    Verifiers internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (Verifiers memory result) {
        result = deployedResult;
    }

    constructor(GatewayVerifiersDeployerConfig memory _config) {
        if (_config.isZKsyncOS) {
            revert WrongCTMDeployerVariant();
        }
        bytes32 salt = _config.salt;

        Verifiers memory result;

        // Deploy Era verifiers
        result.verifierFflonk = address(new EraVerifierFflonk{salt: salt}());
        result.verifierPlonk = address(new EraVerifierPlonk{salt: salt}());

        // Deploy main verifier
        if (_config.testnetVerifier) {
            result.verifier = address(
                new EraTestnetVerifier{salt: salt}(IVerifierV2(result.verifierFflonk), IVerifier(result.verifierPlonk))
            );
        } else {
            result.verifier = address(
                new EraDualVerifier{salt: salt}(IVerifierV2(result.verifierFflonk), IVerifier(result.verifierPlonk))
            );
        }

        deployedResult = result;
    }
}
