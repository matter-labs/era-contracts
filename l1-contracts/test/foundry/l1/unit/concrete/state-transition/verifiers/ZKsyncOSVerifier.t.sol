// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    EmptyPublicInputsLength,
    EmptyProofLength,
    InvalidMockProofLength,
    InvalidProof,
    MockVerifierNotSupported,
    NonZeroCarriedHash,
    UnknownVerifierType
} from "contracts/common/L1ContractErrors.sol";
import {
    MAINNET_CHAIN_ID,
    ZKSYNC_OS_MOCK_PROOF_LENGTH,
    ZKSYNC_OS_MOCK_PROOF_MAGIC,
    ZKSYNC_OS_MOCK_VERIFICATION_TYPE,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE,
    ZKSYNC_OS_PROOF_METADATA_LENGTH,
    PUBLIC_INPUT_SHIFT
} from "contracts/common/Config.sol";

/// @notice Isolates wrapper routing and input handling from the generated cryptographic verifier.
contract MockPlonkVerifierOS is IVerifier {
    bytes32 public constant VK_HASH = keccak256("plonk_os_vk");
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

/// @notice Unit tests for ZKsyncOSVerifier contract.
contract ZKsyncOSVerifierTest is Test {
    ZKsyncOSVerifier public verifier;
    ZKsyncOSTestnetVerifier internal testnetVerifier;
    MockPlonkVerifierOS public plonkVerifier;

    uint256 internal constant REMOVED_FFLONK_VERIFICATION_TYPE = 0;
    uint256 internal constant FORMER_VERIFIER_VERSION = 99;
    uint256 internal constant FORMER_VERIFIER_VERSION_SHIFT = 8;

    function setUp() public {
        plonkVerifier = new MockPlonkVerifierOS();
        verifier = new ZKsyncOSVerifier(IVerifier(address(plonkVerifier)));
        testnetVerifier = new ZKsyncOSTestnetVerifier(IVerifier(address(plonkVerifier)));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsPlonkVerifier() public view {
        assertEq(address(verifier.PLONK_VERIFIER()), address(plonkVerifier));
    }

    function test_testnetConstructor_revertsOnMainnet() public {
        vm.chainId(MAINNET_CHAIN_ID);

        vm.expectRevert();
        new ZKsyncOSTestnetVerifier(IVerifier(address(plonkVerifier)));
    }

    // ============ isTestnetVerifier Tests ============

    function test_isTestnetVerifier_falseOnProductionVerifier() public view {
        assertFalse(verifier.isTestnetVerifier());
    }

    function test_isTestnetVerifier_trueOnTestnetVerifier() public view {
        assertTrue(testnetVerifier.isTestnetVerifier());
    }

    // ============ verify Tests ============

    function test_verify_routesToPlonkVerifier() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with PLONK type (2) as first element
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        proof[1] = 0; // initial hash
        proof[2] = 789;
        proof[3] = 101112;

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

    function test_verify_revertsOnPlonkProofMissingInitialHash() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;
        uint256[] memory proof = new uint256[](1);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;

        vm.expectRevert(EmptyProofLength.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnMockProofMissingInitialHash() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;
        uint256[] memory proof = new uint256[](1);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;

        vm.expectRevert(EmptyProofLength.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnEmptyPublicInputs() public {
        uint256[] memory emptyPublicInputs = new uint256[](0);
        uint256[] memory proof = new uint256[](ZKSYNC_OS_PROOF_METADATA_LENGTH);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;

        vm.expectRevert(EmptyPublicInputsLength.selector);
        verifier.verify(emptyPublicInputs, proof);
    }

    function test_verify_revertsOnRemovedFflonkType() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // FFLONK used type 0 before its removal from the ZKsync OS verifier.
        uint256[] memory proof = new uint256[](4);
        proof[0] = REMOVED_FFLONK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnFormerVersionEncoding() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // The whole first word is now the verifier type; the former version encoding is unknown.
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE | (FORMER_VERIFIER_VERSION << FORMER_VERIFIER_VERSION_SHIFT);
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_mockVerifierReverts() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with MOCK type (3)
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(MockVerifierNotSupported.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_testnetVerifier_acceptsMockProof() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = _mockProof(publicInputs);

        assertTrue(testnetVerifier.verify(publicInputs, proof));
    }

    function test_testnetVerifier_revertsOnInvalidMockProofLength() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;
        uint256[] memory proof = new uint256[](ZKSYNC_OS_PROOF_METADATA_LENGTH);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;

        vm.expectRevert(InvalidMockProofLength.selector);
        testnetVerifier.verify(publicInputs, proof);
    }

    function test_testnetVerifier_revertsOnInvalidMockProofMagic() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;
        uint256[] memory proof = _mockProof(publicInputs);
        proof[ZKSYNC_OS_PROOF_METADATA_LENGTH] = ZKSYNC_OS_MOCK_PROOF_MAGIC + 1;

        vm.expectRevert(InvalidProof.selector);
        testnetVerifier.verify(publicInputs, proof);
    }

    function test_testnetVerifier_revertsOnMismatchedMockPublicInput() public {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 123;
        uint256[] memory proof = _mockProof(publicInputs);
        proof[ZKSYNC_OS_PROOF_METADATA_LENGTH + 1] += 1;

        vm.expectRevert(InvalidProof.selector);
        testnetVerifier.verify(publicInputs, proof);
    }

    function test_verify_plonkReturnsFalse() public {
        plonkVerifier.setShouldVerify(false);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertFalse(result);
    }

    // ============ verificationKeyHash Tests ============

    function test_verificationKeyHash_returnsPlonkHash() public view {
        bytes32 vkHash = verifier.verificationKeyHash();
        assertEq(vkHash, plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_withTypePlonk() public view {
        bytes32 vkHash = verifier.verificationKeyHash(ZKSYNC_OS_PLONK_VERIFICATION_TYPE);
        assertEq(vkHash, plonkVerifier.VK_HASH());
    }

    function test_verificationKeyHash_revertsOnUnknownType() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(0); // Unknown type for ZKsync OS
    }

    function test_verificationKeyHash_revertsOnFormerVersionEncoding() public {
        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(
            ZKSYNC_OS_PLONK_VERIFICATION_TYPE | (FORMER_VERIFIER_VERSION << FORMER_VERIFIER_VERSION_SHIFT)
        );
    }

    // ============ computeZKsyncOSHash Tests ============

    function test_computeZKsyncOSHash_multipleInputs() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 100;
        publicInputs[1] = 200;

        uint256 result = verifier.computeZKsyncOSHash(0, publicInputs);

        uint256 expected = uint256(keccak256(abi.encodePacked(publicInputs))) >> PUBLIC_INPUT_SHIFT;

        assertEq(result, expected);
    }

    function test_computeZKsyncOSHash_singleInput() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 100;

        uint256 result = verifier.computeZKsyncOSHash(0, publicInputs);

        assertEq(result, publicInputs[0] >> PUBLIC_INPUT_SHIFT);
    }

    function testFuzz_computeZKsyncOSHash_revertsOnNonZeroCarriedHash(uint256 _initialHash) public {
        vm.assume(_initialHash != 0);
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 100;
        publicInputs[1] = 200;

        vm.expectRevert(NonZeroCarriedHash.selector);
        verifier.computeZKsyncOSHash(_initialHash, publicInputs);
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeZKsyncOSHash_deterministicResults(uint256 _input1, uint256 _input2) public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = _input1;
        publicInputs[1] = _input2;

        uint256 result1 = verifier.computeZKsyncOSHash(0, publicInputs);
        uint256 result2 = verifier.computeZKsyncOSHash(0, publicInputs);

        assertEq(result1, result2);
    }

    function testFuzz_verify_revertsOnUnknownType(uint256 _verifierType) public {
        vm.assume(
            _verifierType != ZKSYNC_OS_PLONK_VERIFICATION_TYPE && _verifierType != ZKSYNC_OS_MOCK_VERIFICATION_TYPE
        );

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](4);
        proof[0] = _verifierType;
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function testFuzz_verificationKeyHash_revertsOnUnknownType(uint256 _verifierType) public {
        vm.assume(_verifierType != ZKSYNC_OS_PLONK_VERIFICATION_TYPE);

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verificationKeyHash(_verifierType);
    }

    function _mockProof(uint256[] memory _publicInputs) private view returns (uint256[] memory proof) {
        proof = new uint256[](ZKSYNC_OS_PROOF_METADATA_LENGTH + ZKSYNC_OS_MOCK_PROOF_LENGTH);
        proof[0] = ZKSYNC_OS_MOCK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = ZKSYNC_OS_MOCK_PROOF_MAGIC;
        proof[3] = verifier.computeZKsyncOSHash(0, _publicInputs);
    }
}
