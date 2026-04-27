// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType} from "contracts/common/L1ContractErrors.sol";

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

/// @notice Mock Airbender PLONK verifier for testing.
/// @dev Distinct contract so we can assert which verifier received the call.
contract MockAirbenderPlonkVerifier is IVerifier {
    bytes32 public constant VK_HASH = keccak256("airbender_plonk_vk");
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

/// @notice Unit tests for DualVerifier routing between Boojum FFLONK, Boojum PLONK, and Airbender PLONK verifiers.
contract DualVerifierTest is Test {
    DualVerifier internal verifier;
    MockFflonkVerifier internal fflonkVerifier;
    MockPlonkVerifier internal plonkVerifier;
    MockAirbenderPlonkVerifier internal airbenderVerifier;

    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    function setUp() public {
        fflonkVerifier = new MockFflonkVerifier();
        plonkVerifier = new MockPlonkVerifier();
        airbenderVerifier = new MockAirbenderPlonkVerifier();
        verifier = new DualVerifier(
            IVerifierV2(address(fflonkVerifier)),
            IVerifier(address(plonkVerifier)),
            IVerifier(address(airbenderVerifier))
        );
    }

    function _makeProof(uint256 _verifierType) internal pure returns (uint256[] memory proof) {
        proof = new uint256[](3);
        proof[0] = _verifierType;
        proof[1] = 789;
        proof[2] = 101112;
    }

    function _makePublicInputs() internal pure returns (uint256[] memory publicInputs) {
        publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;
    }

    // ============ Constructor Tests ============

    function test_constructor_setsAllVerifiers() public view {
        assertEq(address(verifier.FFLONK_VERIFIER()), address(fflonkVerifier));
        assertEq(address(verifier.PLONK_VERIFIER()), address(plonkVerifier));
        assertEq(address(verifier.AIRBENDER_PLONK_VERIFIER()), address(airbenderVerifier));
    }

    // ============ verify Routing Tests ============

    function test_verify_routesToFflonk() public view {
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(FFLONK_VERIFICATION_TYPE)));
    }

    function test_verify_routesToPlonk() public view {
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(PLONK_VERIFICATION_TYPE)));
    }

    function test_verify_routesToAirbenderPlonk() public view {
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(AIRBENDER_PLONK_VERIFICATION_TYPE)));
    }

    function test_verify_routesToAirbenderPlonk_returnsFalseWhenMockFails() public {
        // When only the Airbender verifier fails, a proof tagged as Airbender should surface the failure,
        // while proofs for other verifiers must remain unaffected.
        airbenderVerifier.setShouldVerify(false);
        assertFalse(verifier.verify(_makePublicInputs(), _makeProof(AIRBENDER_PLONK_VERIFICATION_TYPE)));
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(FFLONK_VERIFICATION_TYPE)));
        assertTrue(verifier.verify(_makePublicInputs(), _makeProof(PLONK_VERIFICATION_TYPE)));
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

    function test_verificationKeyHash_airbenderPlonk() public view {
        assertEq(verifier.verificationKeyHash(AIRBENDER_PLONK_VERIFICATION_TYPE), airbenderVerifier.VK_HASH());
    }

    function test_verificationKeyHash_revertsOnUnknownType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(3);
    }

    // ============ Fuzz Tests ============

    function testFuzz_verify_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(
            verifierType != FFLONK_VERIFICATION_TYPE &&
                verifierType != PLONK_VERIFICATION_TYPE &&
                verifierType != AIRBENDER_PLONK_VERIFICATION_TYPE
        );

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(_makePublicInputs(), _makeProof(verifierType));
    }

    function testFuzz_verificationKeyHash_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(
            verifierType != FFLONK_VERIFICATION_TYPE &&
                verifierType != PLONK_VERIFICATION_TYPE &&
                verifierType != AIRBENDER_PLONK_VERIFICATION_TYPE
        );

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(verifierType);
    }
}
