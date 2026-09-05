// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {DeployCTML1OrGateway} from "deploy-scripts/ctm/DeployCTML1OrGateway.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";

/// @dev Drives the verifier stage of `DeployCTM` on its own. The stage needs
///      only the verifier fields of the config, so this reaches them directly
///      instead of standing up a Bridgehub for the whole CTM deployment.
contract MultiProofVerifierDeployer is DeployCTMScript {
    function deployMultiProofLane(address _owner, address _ziskPlonk, bool _testnet) public {
        config.isZKsyncOS = true;
        config.testnetVerifier = _testnet;
        config.multiProofVerifier = true;
        config.ownerAddress = _owner;
        config.ziskPlonkVerifierAddr = _ziskPlonk;
        deployVerifiers();
    }

    function chainVerifier() public view returns (address) {
        return ctmAddresses.stateTransition.verifiers.verifier;
    }

    function verifierFflonk() public view returns (address) {
        return ctmAddresses.stateTransition.verifiers.verifierFflonk;
    }

    function verifierPlonk() public view returns (address) {
        return ctmAddresses.stateTransition.verifiers.verifierPlonk;
    }

    function airbenderVerifier() public view returns (address) {
        return multiProofAddresses.airbenderVerifier;
    }

    function ziskVerifier() public view returns (address) {
        return multiProofAddresses.ziskVerifier;
    }

    function multiProofVerifier() public view returns (address) {
        return multiProofAddresses.multiProofVerifier;
    }
}

/// @notice Deployment tests for the ZiSK multi-proof verifier lane: the
///         composition the deploy builds, the sub-verifier registration it
///         performs, and the introspection the deployment and upgrade tooling
///         runs against the chain's verifier.
contract MultiProofVerifierDeploymentTest is Test {
    /// @dev Must equal `DeployCTML1OrGateway.DEFAULT_ZKSYNC_OS_VERIFIER_VERSION`.
    uint32 internal constant DEFAULT_ZKSYNC_OS_VERIFIER_VERSION = 6;

    MultiProofVerifierDeployer internal deployer;
    address internal owner;
    address internal ziskPlonk;

    function setUp() public {
        deployer = new MultiProofVerifierDeployer();
        owner = makeAddr("verifierOwner");
        ziskPlonk = makeAddr("ziskSnarkPlonkVerifier");
    }

    /// @dev The testnet lane puts `MultiProofTestnetVerifier` in the CTM, over
    ///      `MultiProofVerifier`, over the ZKsync OS dual verifier.
    function test_testnetLane_composition() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);

        address chainVerifier = deployer.chainVerifier();
        address multiProof = deployer.multiProofVerifier();

        assertGt(chainVerifier.code.length, 0, "chain verifier code");
        assertEq(
            address(MultiProofTestnetVerifier(chainVerifier).INNER_VERIFIER()),
            multiProof,
            "testnet wrapper wraps MultiProofVerifier"
        );
        assertEq(
            address(MultiProofVerifier(multiProof).airbenderVerifier()),
            deployer.airbenderVerifier(),
            "Airbender inner verifier is the dual verifier"
        );
        assertEq(
            address(MultiProofVerifier(multiProof).ziskRangeVerifier()),
            deployer.ziskVerifier(),
            "ZiSK range verifier"
        );
        assertEq(MultiProofVerifier(multiProof).pendingOwner(), owner, "MultiProofVerifier handover");
    }

    /// @dev The production lane puts `MultiProofVerifier` in the CTM directly.
    function test_prodLane_composition() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, false);

        assertEq(deployer.chainVerifier(), deployer.multiProofVerifier(), "chain verifier is MultiProofVerifier");
    }

    /// @dev The dual verifier holds the sub-verifier registry, and the deploy
    ///      registers the pair at the default version and hands the verifier
    ///      over.
    function test_dualVerifier_registersSubVerifiersAtDefaultVersion() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);

        ZKsyncOSDualVerifier dualVerifier = ZKsyncOSDualVerifier(deployer.airbenderVerifier());

        assertEq(
            address(dualVerifier.fflonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION)),
            deployer.verifierFflonk(),
            "FFLONK at the default version"
        );
        assertEq(
            address(dualVerifier.plonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION)),
            deployer.verifierPlonk(),
            "PLONK at the default version"
        );
        assertEq(dualVerifier.pendingOwner(), owner, "dual verifier handover");
    }

    /// @dev The tooling introspects the sub-verifier registry through whichever
    ///      contract the CTM holds, so both compositions must answer.
    function test_tooling_introspectsChainVerifier() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);
        (address fflonk, address plonk) = DeployCTML1OrGateway.getSubVerifiers(deployer.chainVerifier(), true);
        assertEq(fflonk, deployer.verifierFflonk(), "testnet lane FFLONK");
        assertEq(plonk, deployer.verifierPlonk(), "testnet lane PLONK");

        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        (fflonk, plonk) = DeployCTML1OrGateway.getSubVerifiers(deployer.chainVerifier(), true);
        assertEq(fflonk, deployer.verifierFflonk(), "prod lane FFLONK");
        assertEq(plonk, deployer.verifierPlonk(), "prod lane PLONK");
    }
}
