// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraVerifierFflonk} from "../../verifiers/EraVerifierFflonk.sol";
import {EraMultiProofVerifier} from "../../verifiers/EraMultiProofVerifier.sol";
import {EraMultiProofTestnetVerifier} from "../../verifiers/EraMultiProofTestnetVerifier.sol";

import {IVerifier} from "../../chain-interfaces/IVerifier.sol";

import {WrongCTMDeployerVariant} from "../../../common/L1ContractErrors.sol";

import {Verifiers} from "contracts/common/StateTransitionTypes.sol";
import {GatewayVerifiersDeployerConfig} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerVerifiers
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM Era Verifiers deployer: deploys Era verifier contracts.
/// @dev Deploys EraVerifierFflonk and the chain verifier EraMultiProofVerifier/EraMultiProofTestnetVerifier over it.
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

        result.verifierFflonk = address(new EraVerifierFflonk{salt: salt}());

        // No Airbender verifier is deployed on Gateway, so Gateway chains require Boojum only.
        if (_config.testnetVerifier) {
            result.verifier = address(
                new EraMultiProofTestnetVerifier{salt: salt}(IVerifier(result.verifierFflonk), IVerifier(address(0)))
            );
        } else {
            result.verifier = address(
                new EraMultiProofVerifier{salt: salt}(IVerifier(result.verifierFflonk), IVerifier(address(0)))
            );
        }

        deployedResult = result;
    }
}
