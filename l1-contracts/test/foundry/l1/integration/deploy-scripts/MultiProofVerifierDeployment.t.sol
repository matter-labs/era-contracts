// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {DeployCTML1OrGateway} from "deploy-scripts/ctm/DeployCTML1OrGateway.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {ZiskTestnetVerifier} from "contracts/state-transition/verifiers/ZiskTestnetVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";

/// @dev Drives the verifier stage of `DeployCTM` on its own. The stage needs
///      only the verifier fields of the config, so this reaches them directly
///      instead of standing up a Bridgehub for the whole CTM deployment.
contract MultiProofVerifierDeployer is DeployCTMScript {
    function deployMultiProofLane(address _owner, address _ziskPlonk, bool _testnet) public {
        deployMultiProofLane(_owner, _ziskPlonk, _testnet, address(0));
    }

    function deployMultiProofLane(address _owner, address _ziskPlonk, bool _testnet, address _ziskRange) public {
        config.multiProof.ziskRangeVerifierAddr = _ziskRange;
        config.testnetVerifier = _testnet;
        config.multiProof.enabled = true;
        config.ownerAddress = _owner;
        config.multiProof.ziskPlonkVerifierAddr = _ziskPlonk;
        deployVerifiers();
    }

    function writeOutput(string memory _path) public {
        saveOutput(_path);
    }

    function deployAirbenderLane(bool _testnet) public {
        config.testnetVerifier = _testnet;
        config.multiProof.enabled = false;
        deployVerifiers();
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
        CTMDeployedAddresses memory addresses = deployer.getAddresses();

        address chainVerifier = addresses.stateTransition.verifiers.verifier;
        address multiProof = addresses.multiProof.multiProofVerifier;

        assertGt(chainVerifier.code.length, 0, "chain verifier code");
        assertEq(
            address(MultiProofTestnetVerifier(chainVerifier).INNER_VERIFIER()),
            multiProof,
            "testnet wrapper wraps MultiProofVerifier"
        );
        assertEq(
            address(MultiProofVerifier(multiProof).AIRBENDER_VERIFIER()),
            addresses.multiProof.airbenderVerifier,
            "Airbender inner verifier"
        );
        assertTrue(
            ZKsyncOSTestnetVerifier(addresses.multiProof.airbenderVerifier).isTestnetVerifier(),
            "Airbender inner accepts canonical fake components"
        );
        assertEq(
            address(MultiProofVerifier(multiProof).ZISK_RANGE_VERIFIER()),
            addresses.multiProof.ziskTestnetVerifier,
            "ZiSK testnet range verifier"
        );
        assertEq(
            address(ZiskTestnetVerifier(addresses.multiProof.ziskTestnetVerifier).INNER_VERIFIER()),
            addresses.multiProof.ziskVerifier,
            "ZiSK testnet verifier wraps the real range verifier"
        );
    }

    /// @dev The production lane puts `MultiProofVerifier` in the CTM directly.
    function test_prodLane_composition() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        CTMDeployedAddresses memory addresses = deployer.getAddresses();

        assertEq(
            addresses.stateTransition.verifiers.verifier,
            addresses.multiProof.multiProofVerifier,
            "chain verifier is MultiProofVerifier"
        );
        assertEq(
            address(MultiProofVerifier(addresses.multiProof.multiProofVerifier).ZISK_RANGE_VERIFIER()),
            addresses.multiProof.ziskVerifier,
            "production lane uses the real ZiSK verifier"
        );
    }

    function testFuzz_singleProver_addressesHaveNoMultiproverComponents(bool _testnet) public {
        deployer.deployAirbenderLane(_testnet);
        _assertAirbenderOnlyAddresses();
    }

    function test_repeatedDeployment_clearsUnusedComponents() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);
        assertGt(deployer.getAddresses().multiProof.ziskTestnetVerifier.code.length, 0);
        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        assertEq(deployer.getAddresses().multiProof.ziskTestnetVerifier, address(0));
        deployer.deployAirbenderLane(false);
        _assertAirbenderOnlyAddresses();
    }

    function _assertAirbenderOnlyAddresses() internal view {
        CTMDeployedAddresses memory addresses = deployer.getAddresses();
        assertGt(addresses.stateTransition.verifiers.verifier.code.length, 0);
        assertEq(
            address(ZKsyncOSVerifier(addresses.stateTransition.verifiers.verifier).PLONK_VERIFIER()),
            addresses.stateTransition.verifiers.verifierPlonk
        );
        assertEq(addresses.multiProof.airbenderVerifier, address(0));
        assertEq(addresses.multiProof.ziskVerifier, address(0));
        assertEq(addresses.multiProof.ziskTestnetVerifier, address(0));
        assertEq(addresses.multiProof.multiProofVerifier, address(0));
    }

    function test_rangeVerifierWithoutCode_revertsDeployment() public {
        vm.expectRevert("zisk_range_verifier_addr holds no code: deploy the range verifier first");
        deployer.deployMultiProofLane(owner, ziskPlonk, false, makeAddr("missingRangeVerifier"));
    }

    function testFuzz_rangeVerifierOverride_wiringAndOutput(bool _testnet) public {
        // Only address selection is under test; proof verification has separate suites.
        address rangeVerifier = makeAddr("externalRangeVerifier");
        vm.etch(rangeVerifier, hex"fe");
        deployer.deployMultiProofLane(owner, ziskPlonk, _testnet, rangeVerifier);
        CTMDeployedAddresses memory addresses = deployer.getAddresses();

        address selected = address(MultiProofVerifier(addresses.multiProof.multiProofVerifier).ZISK_RANGE_VERIFIER());
        if (_testnet) {
            assertEq(selected, addresses.multiProof.ziskTestnetVerifier);
            selected = address(ZiskTestnetVerifier(selected).INNER_VERIFIER());
        }
        assertEq(selected, rangeVerifier);
        assertEq(addresses.multiProof.ziskVerifier, rangeVerifier);
        _assertOutputRangeVerifier(rangeVerifier);
    }

    function test_defaultRangeVerifier_output() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        _assertOutputRangeVerifier(deployer.getAddresses().multiProof.ziskVerifier);
    }

    function _assertOutputRangeVerifier(address _expected) internal {
        string memory outputPath = string.concat(
            "test/foundry/l1/integration/deploy-scripts/script-out/multiproof-",
            vm.toString(_expected),
            ".toml"
        );
        deployer.writeOutput(outputPath);
        string memory output = vm.readFile(outputPath);
        CTMDeployedAddresses memory addresses = deployer.getAddresses();
        assertEq(addresses.multiProof.ziskVerifier, _expected);
        assertEq(vm.parseTomlAddress(output, ".deployed_addresses.state_transition.zisk_verifier_addr"), _expected);
        assertEq(
            vm.parseTomlAddress(output, ".deployed_addresses.state_transition.airbender_verifier_addr"),
            addresses.multiProof.airbenderVerifier
        );
        assertEq(
            vm.parseTomlAddress(output, ".deployed_addresses.state_transition.multi_proof_verifier_addr"),
            addresses.multiProof.multiProofVerifier
        );
        assertEq(
            vm.parseTomlAddress(output, ".deployed_addresses.state_transition.verifier_addr"),
            addresses.stateTransition.verifiers.verifier
        );
        if (addresses.multiProof.ziskTestnetVerifier != address(0)) {
            assertEq(
                vm.parseTomlAddress(output, ".deployed_addresses.state_transition.zisk_testnet_verifier_addr"),
                addresses.multiProof.ziskTestnetVerifier
            );
        }
        vm.removeFile(outputPath);
    }

    /// @dev The ZKsync OS verifier holds the PLONK sub-verifier, which the
    ///      deploy wires at construction.
    function test_airbenderVerifier_wiresPlonkSubVerifier() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);
        CTMDeployedAddresses memory addresses = deployer.getAddresses();

        ZKsyncOSVerifier airbenderVerifier = ZKsyncOSVerifier(addresses.multiProof.airbenderVerifier);

        assertEq(
            address(airbenderVerifier.PLONK_VERIFIER()),
            addresses.stateTransition.verifiers.verifierPlonk,
            "PLONK sub-verifier"
        );
    }

    /// @dev The tooling introspects the sub-verifier through whichever contract
    ///      the CTM holds, so both compositions must answer.
    function test_tooling_introspectsChainVerifier() public {
        deployer.deployMultiProofLane(owner, ziskPlonk, true);
        (, address plonk) = DeployCTML1OrGateway.getSubVerifiers(
            deployer.getAddresses().stateTransition.verifiers.verifier
        );
        assertEq(plonk, deployer.getAddresses().stateTransition.verifiers.verifierPlonk, "testnet lane PLONK");
        assertTrue(
            MultiProofTestnetVerifier(deployer.getAddresses().stateTransition.verifiers.verifier).isTestnetVerifier()
        );

        deployer.deployMultiProofLane(owner, ziskPlonk, false);
        (, plonk) = DeployCTML1OrGateway.getSubVerifiers(deployer.getAddresses().stateTransition.verifiers.verifier);
        assertEq(plonk, deployer.getAddresses().stateTransition.verifiers.verifierPlonk, "prod lane PLONK");
        assertFalse(MultiProofVerifier(deployer.getAddresses().stateTransition.verifiers.verifier).isTestnetVerifier());
    }
}
