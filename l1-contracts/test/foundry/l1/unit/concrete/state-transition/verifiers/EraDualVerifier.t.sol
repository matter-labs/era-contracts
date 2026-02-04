// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock FFLONK verifier for testing
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

/// @notice Mock PLONK verifier for testing
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

/// @notice Unit tests for EraDualVerifier contract
contract EraDualVerifierTest is Test {
    EraDualVerifier public verifier;
    MockFflonkVerifier public fflonkVerifier;
    MockPlonkVerifier public plonkVerifier;

    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    function setUp() public {
        fflonkVerifier = new MockFflonkVerifier();
        plonkVerifier = new MockPlonkVerifier();
        verifier = new EraDualVerifier(IVerifierV2(address(fflonkVerifier)), IVerifier(address(plonkVerifier)));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsVerifiers() public view {
        assertEq(address(verifier.FFLONK_VERIFIER()), address(fflonkVerifier));
        assertEq(address(verifier.PLONK_VERIFIER()), address(plonkVerifier));
    }

    // ============ verify Tests ============

    function test_verify_routesToFflonkVerifier() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with FFLONK type (0) as first element
        uint256[] memory proof = new uint256[](3);
        proof[0] = FFLONK_VERIFICATION_TYPE; // FFLONK type
        proof[1] = 789;
        proof[2] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }

    function test_verify_routesToPlonkVerifier() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with PLONK type (1) as first element
        uint256[] memory proof = new uint256[](3);
        proof[0] = PLONK_VERIFICATION_TYPE; // PLONK type
        proof[1] = 789;
        proof[2] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }

    function test_verify_revertsOnEmptyProof() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory emptyProof = new uint256[](0);

        vm.expectRevert(EmptyProofLength.selector);
        verifier.verify(publicInputs, emptyProof);
    }

    function test_verify_revertsOnUnknownVerifierType() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with unknown type (2) as first element
        uint256[] memory proof = new uint256[](3);
        proof[0] = 2; // Unknown type
        proof[1] = 789;
        proof[2] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_fflonkReturnsFalse() public {
        fflonkVerifier.setShouldVerify(false);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](3);
        proof[0] = FFLONK_VERIFICATION_TYPE;
        proof[1] = 789;
        proof[2] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertFalse(result);
    }

    function test_verify_plonkReturnsFalse() public {
        plonkVerifier.setShouldVerify(false);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](3);
        proof[0] = PLONK_VERIFICATION_TYPE;
        proof[1] = 789;
        proof[2] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertFalse(result);
    }

    function test_verify_singleElementProofFflonk() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;

        // Proof with only type indicator
        uint256[] memory proof = new uint256[](1);
        proof[0] = FFLONK_VERIFICATION_TYPE;

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }

    function test_verify_singleElementProofPlonk() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;

        uint256[] memory proof = new uint256[](1);
        proof[0] = PLONK_VERIFICATION_TYPE;

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }

    // ============ verificationKeyHash Tests ============

    function test_verificationKeyHash_returnsPlonkHash() public view {
        bytes32 vkHash = verifier.verificationKeyHash();
        assertEq(vkHash, plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_withTypeFflonk() public view {
        bytes32 vkHash = verifier.verificationKeyHash(FFLONK_VERIFICATION_TYPE);
        assertEq(vkHash, fflonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_withTypePlonk() public view {
        bytes32 vkHash = verifier.verificationKeyHash(PLONK_VERIFICATION_TYPE);
        assertEq(vkHash, plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_revertsOnUnknownType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_verify_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(verifierType != FFLONK_VERIFICATION_TYPE && verifierType != PLONK_VERIFICATION_TYPE);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](3);
        proof[0] = verifierType;
        proof[1] = 789;
        proof[2] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function testFuzz_verificationKeyHash_revertsOnUnknownType(uint256 verifierType) public {
        vm.assume(verifierType != FFLONK_VERIFICATION_TYPE && verifierType != PLONK_VERIFICATION_TYPE);

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(verifierType);
    }

    function testFuzz_verify_fflonkWithArbitraryProof(uint256[] memory proofData) public view {
        vm.assume(proofData.length > 0);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](proofData.length + 1);
        proof[0] = FFLONK_VERIFICATION_TYPE;
        for (uint256 i = 0; i < proofData.length; i++) {
            proof[i + 1] = proofData[i];
        }

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }

    function testFuzz_verify_plonkWithArbitraryProof(uint256[] memory proofData) public view {
        vm.assume(proofData.length > 0);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](proofData.length + 1);
        proof[0] = PLONK_VERIFICATION_TYPE;
        for (uint256 i = 0; i < proofData.length; i++) {
            proof[i + 1] = proofData[i];
        }

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
    }
}
