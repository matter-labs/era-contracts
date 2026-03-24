// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSVerifierFflonk} from "../../verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "../../verifiers/ZKsyncOSVerifierPlonk.sol";
import {ZKsyncOSDualVerifier} from "../../verifiers/ZKsyncOSDualVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "../../verifiers/ZKsyncOSTestnetVerifier.sol";

import {IVerifier} from "../../chain-interfaces/IVerifier.sol";
import {IVerifierV2} from "../../chain-interfaces/IVerifierV2.sol";

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

        // Deploy main verifier with address(this) as initial owner so we can register
        // the initial verifier version before transferring ownership to governance.
        ZKsyncOSDualVerifier verifier;
        if (_config.testnetVerifier) {
            verifier = ZKsyncOSDualVerifier(
                address(
                    new ZKsyncOSTestnetVerifier{salt: salt}(
                        IVerifierV2(result.verifierFflonk),
                        IVerifier(result.verifierPlonk),
                        address(this)
                    )
                )
            );
        } else {
            verifier = new ZKsyncOSDualVerifier{salt: salt}(
                IVerifierV2(result.verifierFflonk),
                IVerifier(result.verifierPlonk),
                address(this)
            );
        }

        if (_config.initialVerifierVersion != 0) {
            verifier.addVerifier(
                _config.initialVerifierVersion,
                IVerifierV2(result.verifierFflonk),
                IVerifier(result.verifierPlonk)
            );
        }

        verifier.transferOwnership(_config.aliasedGovernanceAddress);
        result.verifier = address(verifier);

        deployedResult = result;
    }
}
