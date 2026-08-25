// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {DeployCTML1OrGateway} from "deploy-scripts/ctm/DeployCTML1OrGateway.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";

/// @dev Drives the verifier stage of `DeployCTM` on its own. The stage needs
///      only the verifier fields of the config, so this reaches them directly
///      instead of standing up a Bridgehub for the whole CTM deployment.
contract MultiProofVerifierDeployer is DeployCTMScript {
    function deployMultiProofLane(address _owner, address _ziskPlonk, bool _testnet) public {
        config.isZKsyncOS = true;
        config.testnetVerifier = _testnet;
        config.multiProof.enabled = true;
        config.ownerAddress = _owner;
        config.multiProof.ziskPlonkVerifierAddr = _ziskPlonk;
        deployVerifiers();
    }

    function chainVerifier() public view returns (address) {
        return ctmAddresses.stateTransition.verifiers.verifier;
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
///         composition the deploy builds, the sub-verifier it wires, and the
///         introspection the deployment and upgrade tooling runs against the
///         chain's verifier.
contract MultiProofVerifierDeploymentTest is Test {
    MultiProofVerifierDeployer internal deployer;
    address internal owner;
    address internal ziskPlonk;

    function setUp() public {
        deployer = new MultiProofVerifierDeployer();
        owner = makeAddr("verifierOwner");
        ziskPlonk = makeAddr("ziskSnarkPlonkVerifier");
        // The deploy requires the snarkJS Plonk verifier to be deployed
        // already. These tests read wiring rather than verify a proof, so any
        // code at the address serves.
        vm.etch(ziskPlonk, hex"fe");
    }

    /// @dev The snarkJS Plonk verifier is deployed by hand before the CTM
    ///      deployment runs, so an address that holds no code is an operator
    ///      mistake the deploy refuses rather than carries into settlement.
    function test_plonkVerifierWithoutCode_revertsDeployment() public {
        address notDeployed = makeAddr("neverDeployed");

        vm.expectRevert("zisk_plonk_verifier_addr holds no code: deploy the snarkJS Plonk verifier first");
        deployer.deployMultiProofLane(owner, notDeployed, true);
    }

    /// @dev The testnet lane puts `MultiProofTestnetVerifier` in the CTM, over
    ///      `MultiProofVerifier`, over the ZKsync OS verifier.
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
            address(MultiProofVerifier(multiProof).AIRBENDER_VERIFIER()),
            deployer.airbenderVerifier(),
            "Airbender inner verifier is the ZKsync OS verifier"
        );
        assertEq(
            address(MultiProofVerifier(multiProof).ZISK_RANGE_VERIFIER()),
            deployer.ziskVerifier(),
            "ZiSK range verifier"
        );
    }

    /// @dev The production lane puts `MultiProofVerifier` in the CTM directly.
    function test_prodLane_composition() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, false);

        assertEq(deployer.chainVerifier(), deployer.multiProofVerifier(), "chain verifier is MultiProofVerifier");
    }

    /// @dev The ZKsync OS verifier holds the PLONK sub-verifier, which the
    ///      deploy wires at construction.
    function test_airbenderVerifier_wiresPlonkSubVerifier() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);

        ZKsyncOSVerifier airbenderVerifier = ZKsyncOSVerifier(deployer.airbenderVerifier());

        assertEq(address(airbenderVerifier.PLONK_VERIFIER()), deployer.verifierPlonk(), "PLONK sub-verifier");
    }

    /// @dev The tooling introspects the sub-verifier through whichever contract
    ///      the CTM holds, so both compositions must answer.
    function test_tooling_introspectsChainVerifier() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);
        (, address plonk) = DeployCTML1OrGateway.getSubVerifiers(deployer.chainVerifier(), true);
        assertEq(plonk, deployer.verifierPlonk(), "testnet lane PLONK");

        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        (, plonk) = DeployCTML1OrGateway.getSubVerifiers(deployer.chainVerifier(), true);
        assertEq(plonk, deployer.verifierPlonk(), "prod lane PLONK");
    }
}
