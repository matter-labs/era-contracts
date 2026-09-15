// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {EmptyProofLength, InvalidPublicInputsLength, UnknownVerifierType} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock FFLONK verifier for testing.
contract MockFflonkVerifier is IVerifierV2 {
    bytes32 public constant VK_HASH = keccak256("fflonk_vk");
    bool public shouldVerify = true;

    function verify(uint256[] calldata, uint256[] calldata) external view override returns (bool) {
        return shouldVerify;
    }

    function verificationKeyHash() external pure override returns (bytes32) {
        return VK_HASH;
    }

    function setShouldVerify(bool _value) external {
        shouldVerify = _value;
    }
}

/// @notice Mock PLONK verifier for testing.
contract MockPlonkVerifier is IVerifier {
    bytes32 public constant VK_HASH = keccak256("plonk_vk");
    bool public shouldVerify = true;

    function verify(uint256[] calldata, uint256[] calldata) external view override returns (bool) {
        return shouldVerify;
    }

    function verificationKeyHash() external pure override returns (bytes32) {
        return VK_HASH;
    }

    function setShouldVerify(bool _value) external {
        shouldVerify = _value;
    }
}

/// @notice Sub-verifier that reports back the public input it was handed.
/// @dev `verify` is `view`, so reverting is the only way to observe the argument.
contract PublicInputRevealingSubVerifier is IVerifier, IVerifierV2 {
    error RevealedPublicInput(uint256 publicInput, uint256 length);

    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata
    ) external pure override(IVerifier, IVerifierV2) returns (bool) {
        revert RevealedPublicInput(_publicInputs[0], _publicInputs.length);
    }

    function verificationKeyHash() external pure override(IVerifier, IVerifierV2) returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Unit tests for EraDualVerifier, the Boojum router between the FFLONK and PLONK wrappers.
/// @dev The Airbender lane deliberately does not live here: it is a separate proof system with its own
/// public-input binding, reached only through `AirbenderVerifier`. Keeping a second Airbender route inside
/// this router would let a caller satisfy both halves of a two-proof-system requirement with one system.
contract EraDualVerifierTest is Test {
    EraDualVerifier internal verifier;
    MockFflonkVerifier internal fflonkVerifier;
    MockPlonkVerifier internal plonkVerifier;

    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    function setUp() public {
        fflonkVerifier = new MockFflonkVerifier();
        plonkVerifier = new MockPlonkVerifier();
        verifier = new EraDualVerifier(IVerifierV2(address(fflonkVerifier)), IVerifier(address(plonkVerifier)));
    }

    function _makeProof(uint256 _verifierType) internal pure returns (uint256[] memory proof) {
        proof = new uint256[](3);
        proof[0] = _verifierType;
        proof[1] = 789;
        proof[2] = 101112;
    }

    function _makePublicInputs() internal pure returns (uint256[] memory publicInputs) {
        publicInputs = new uint256[](1);
        publicInputs[0] = 123;
    }

    // ============ Constructor Tests ============

    function test_constructor_setsAllVerifiers() public view {
        assertEq(address(verifier.FFLONK_VERIFIER()), address(fflonkVerifier));
        assertEq(address(verifier.PLONK_VERIFIER()), address(plonkVerifier));
    }

    // ============ verify Routing Tests ============

    function test_verify_routesToFflonk() public view {
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(FFLONK_VERIFICATION_TYPE)));
    }

    function test_verify_routesToPlonk() public view {
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(PLONK_VERIFICATION_TYPE)));
    }

    /// The Airbender type must not be routable here. If it were, a caller could satisfy the Boojum half
    /// of the dual-prover requirement with an Airbender proof.
    function test_verify_rejectsAirbenderType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(_makePublicInputs(), _makeProof(AIRBENDER_PLONK_VERIFICATION_TYPE));
    }

    function test_verify_revertsOnEmptyProof() public {
        uint256[] memory emptyProof = new uint256[](0);
        vm.expectRevert(EmptyProofLength.selector);
        verifier.verify(_makePublicInputs(), emptyProof);
    }

    function test_verify_revertsOnUnknownVerifierType() public {
        uint256[] memory proof = _makeProof(3);
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(_makePublicInputs(), proof);
    }

    // ============ verificationKeyHash Tests ============

    function test_verificationKeyHash_noArg_returnsPlonkHash() public view {
        assertEq(verifier.verificationKeyHash(), plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_fflonk() public view {
        assertEq(verifier.verificationKeyHash(FFLONK_VERIFICATION_TYPE), fflonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_plonk() public view {
        assertEq(verifier.verificationKeyHash(PLONK_VERIFICATION_TYPE), plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_rejectsAirbenderType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(AIRBENDER_PLONK_VERIFICATION_TYPE);
    }

    function test_verificationKeyHash_revertsOnUnknownType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(3);
    }

    // ============ Fuzz Tests ============

    function testFuzz_verify_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(verifierType != FFLONK_VERIFICATION_TYPE && verifierType != PLONK_VERIFICATION_TYPE);

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(_makePublicInputs(), _makeProof(verifierType));
    }

    function testFuzz_verificationKeyHash_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(verifierType != FFLONK_VERIFICATION_TYPE && verifierType != PLONK_VERIFICATION_TYPE);

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(verifierType);
    }

    // ============ Public input fold and shift ============

    uint256 internal constant PUBLIC_INPUT_SHIFT = 32;

    /// The Executor now emits the untruncated transition hash, so the verifier owns the shift. Mirrors
    /// `ZKsyncOSVerifier.computeZKsyncOSHash`, which applies `PUBLIC_INPUT_SHIFT` once after the fold.
    function _verifierRevealing() internal returns (EraDualVerifier revealing, uint256 rawPublicInput) {
        PublicInputRevealingSubVerifier revealer = new PublicInputRevealingSubVerifier();
        revealing = new EraDualVerifier(IVerifierV2(address(revealer)), IVerifier(address(revealer)));
        rawPublicInput = uint256(keccak256("untruncated-transition-hash"));
    }

    function test_verify_shiftsPublicInputForFflonk() public {
        (EraDualVerifier revealing, uint256 raw) = _verifierRevealing();
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = raw;

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputRevealingSubVerifier.RevealedPublicInput.selector,
                raw >> PUBLIC_INPUT_SHIFT,
                uint256(1)
            )
        );
        revealing.verify(publicInputs, _makeProof(FFLONK_VERIFICATION_TYPE));
    }

    function test_verify_shiftsPublicInputForPlonk() public {
        (EraDualVerifier revealing, uint256 raw) = _verifierRevealing();
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = raw;

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputRevealingSubVerifier.RevealedPublicInput.selector,
                raw >> PUBLIC_INPUT_SHIFT,
                uint256(1)
            )
        );
        revealing.verify(publicInputs, _makeProof(PLONK_VERIFICATION_TYPE));
    }

    /// Era proves one batch at a time. Folding a range here would define an aggregation rule that no Era
    /// prover implements, so more than one public input is refused rather than combined.
    function test_verify_rejectsMultiplePublicInputs() public {
        (EraDualVerifier revealing, ) = _verifierRevealing();
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(keccak256("batch-1"));
        publicInputs[1] = uint256(keccak256("batch-2"));

        vm.expectRevert(InvalidPublicInputsLength.selector);
        revealing.verify(publicInputs, _makeProof(PLONK_VERIFICATION_TYPE));
    }

    function test_verify_rejectsEmptyPublicInputs() public {
        (EraDualVerifier revealing, ) = _verifierRevealing();
        vm.expectRevert(InvalidPublicInputsLength.selector);
        revealing.verify(new uint256[](0), _makeProof(PLONK_VERIFICATION_TYPE));
    }
}
