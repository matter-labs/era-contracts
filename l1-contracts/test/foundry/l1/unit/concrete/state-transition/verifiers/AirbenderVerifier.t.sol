// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AirbenderVerifier} from "contracts/state-transition/verifiers/AirbenderVerifier.sol";
import {AirbenderVerifierPlonk} from "contracts/state-transition/verifiers/AirbenderVerifierPlonk.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {InvalidPublicInputsLength} from "contracts/common/L1ContractErrors.sol";
import {AirbenderPlonkProofFixture} from "./fixtures/AirbenderPlonkProofFixture.sol";

/// @notice PLONK verifier stand-in that reports back the public input it was handed.
contract RevealingPlonkVerifier is IVerifier {
    error RevealedPublicInput(uint256 publicInput, uint256 length);

    function verify(uint256[] calldata _publicInputs, uint256[] calldata) external pure returns (bool) {
        revert RevealedPublicInput(_publicInputs[0], _publicInputs.length);
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return keccak256("airbender_plonk_vk");
    }
}

/// @notice Unit tests for `AirbenderVerifier`, the Airbender lane of the Era dual-prover gate.
/// @dev The Executor emits the transition hash untruncated so each proof system can apply its own
/// derivation; this lane applies `PUBLIC_INPUT_SHIFT`. The audited guest binary is bound inside the
/// recursion circuit rather than carried in the SNARK public input, so there is no pin to fold in here —
/// see the contract's note on the prover mode this assumes.
contract AirbenderVerifierTest is Test {
    uint256 internal constant PUBLIC_INPUT_SHIFT = 32;

    RevealingPlonkVerifier internal plonk;
    AirbenderVerifier internal verifier;

    function setUp() public {
        plonk = new RevealingPlonkVerifier();
        verifier = new AirbenderVerifier(IVerifier(address(plonk)));
    }

    function _proof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](2);
        proof[0] = 0xaa;
        proof[1] = 0xbb;
    }

    function _inputs(uint256 _raw) internal pure returns (uint256[] memory inputs) {
        inputs = new uint256[](1);
        inputs[0] = _raw;
    }

    function test_constructor_setsPlonkVerifier() public view {
        assertEq(address(verifier.AIRBENDER_PLONK_VERIFIER()), address(plonk));
    }

    function test_verify_shiftsTheUntruncatedTransitionHash() public {
        uint256 raw = uint256(keccak256("untruncated-transition-hash"));

        vm.expectRevert(
            abi.encodeWithSelector(
                RevealingPlonkVerifier.RevealedPublicInput.selector,
                raw >> PUBLIC_INPUT_SHIFT,
                uint256(1)
            )
        );
        verifier.verify(_inputs(raw), _proof());
    }

    /// Era proves one batch per call. Folding a range here would define an aggregation rule no Era prover
    /// implements, so more than one public input is refused rather than combined.
    function test_verify_rejectsMultiplePublicInputs() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = uint256(keccak256("batch-1"));
        inputs[1] = uint256(keccak256("batch-2"));

        vm.expectRevert(InvalidPublicInputsLength.selector);
        verifier.verify(inputs, _proof());
    }

    function test_verify_rejectsEmptyPublicInputs() public {
        vm.expectRevert(InvalidPublicInputsLength.selector);
        verifier.verify(new uint256[](0), _proof());
    }

    function test_verificationKeyHash_forwardsToPlonk() public view {
        assertEq(verifier.verificationKeyHash(), plonk.verificationKeyHash());
    }

    /// Anchors the derivation against a real proof: feeding this lane the untruncated program output of a
    /// genuine Airbender SNARK must reproduce the public input that proof was generated against, and the
    /// real pairing must accept. If the shift, the byte order, or the wrapper's binding mode ever drift,
    /// this fails.
    function test_verify_acceptsRealAirbenderProof() public {
        AirbenderVerifier real = new AirbenderVerifier(IVerifier(address(new AirbenderVerifierPlonk())));

        uint256 untruncatedProgramOutput = AirbenderPlonkProofFixture.packedProgramOutput();
        assertEq(
            untruncatedProgramOutput >> PUBLIC_INPUT_SHIFT,
            AirbenderPlonkProofFixture.publicInputs()[0],
            "fixture public input is not the shifted program output"
        );

        assertTrue(
            real.verify(_inputs(untruncatedProgramOutput), AirbenderPlonkProofFixture.serializedProof()),
            "real Airbender proof must verify through the lane"
        );
    }
}
