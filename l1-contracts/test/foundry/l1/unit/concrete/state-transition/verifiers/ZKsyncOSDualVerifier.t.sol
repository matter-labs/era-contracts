// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType, MockVerifierNotSupported} from "contracts/common/L1ContractErrors.sol";
import {UnknownVerifierVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Mock PLONK verifier for testing
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

/// @notice Unit tests for ZKsyncOSDualVerifier contract
contract ZKsyncOSDualVerifierTest is Test {
    ZKsyncOSDualVerifier public verifier;
    MockPlonkVerifierOS public plonkVerifier;
    address public owner;

    uint256 internal constant ZKSYNC_OS_PLONK_VERIFICATION_TYPE = 2;
    uint256 internal constant ZKSYNC_OS_MOCK_VERIFICATION_TYPE = 3;

    function setUp() public {
        owner = makeAddr("owner");
        plonkVerifier = new MockPlonkVerifierOS();
        verifier = new ZKsyncOSDualVerifier(IVerifier(address(plonkVerifier)), owner);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsVerifiersAtVersion0() public view {
        assertEq(address(verifier.plonkVerifiers(0)), address(plonkVerifier));
    }

    function test_constructor_setsOwner() public view {
        assertEq(verifier.owner(), owner);
    }

    // ============ addVerifier Tests ============

    function test_addVerifier_ownerCanAdd() public {
        MockPlonkVerifierOS newPlonk = new MockPlonkVerifierOS();

        vm.prank(owner);
        verifier.addVerifier(1, IVerifier(address(newPlonk)));

        assertEq(address(verifier.plonkVerifiers(1)), address(newPlonk));
    }

    function test_addVerifier_revertsIfNotOwner() public {
        MockPlonkVerifierOS newPlonk = new MockPlonkVerifierOS();

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        verifier.addVerifier(1, IVerifier(address(newPlonk)));
    }

    // ============ removeVerifier Tests ============

    function test_removeVerifier_ownerCanRemove() public {
        // First add a verifier
        MockPlonkVerifierOS newPlonk = new MockPlonkVerifierOS();

        vm.prank(owner);
        verifier.addVerifier(1, IVerifier(address(newPlonk)));

        // Then remove it
        vm.prank(owner);
        verifier.removeVerifier(1);

        assertEq(address(verifier.plonkVerifiers(1)), address(0));
    }

    function test_removeVerifier_revertsIfNotOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        verifier.removeVerifier(0);
    }

    // ============ verify Tests ============

    function test_verify_routesToPlonkVerifier() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with PLONK type (2) as first element, version 0
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE; // type 2, version 0
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

    function test_verify_revertsOnUnknownVerifierType() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with unknown type (0) as first element
        uint256[] memory proof = new uint256[](4);
        proof[0] = 0; // Unknown type for ZKsync OS
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnUnknownVerifierVersion() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with type 2 but version 99 (unknown)
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE | (99 << 8); // type 2, version 99
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierVersion.selector);
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

    function test_verify_withDifferentVersion() public {
        // Add verifier at version 1
        MockPlonkVerifierOS newPlonk = new MockPlonkVerifierOS();

        vm.prank(owner);
        verifier.addVerifier(1, IVerifier(address(newPlonk)));

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        // Proof with type 2, version 1
        uint256[] memory proof = new uint256[](4);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE | (1 << 8);
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        bool result = verifier.verify(publicInputs, proof);
        assertTrue(result);
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

    function test_verificationKeyHash_revertsOnUnknownVersion() public {
        vm.expectRevert(UnknownVerifierVersion.selector);
        verifier.verificationKeyHash(ZKSYNC_OS_PLONK_VERIFICATION_TYPE | (99 << 8)); // type 2, version 99
    }

    // ============ computeZKsyncOSHash Tests ============

    function test_computeZKsyncOSHash_withNonZeroInitialHash() public view {
        uint256 initialHash = 12345;
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 100;
        publicInputs[1] = 200;

        uint256 result = verifier.computeZKsyncOSHash(initialHash, publicInputs);

        // Manually compute expected hash
        uint256 expected = initialHash;
        expected = uint256(keccak256(abi.encodePacked(expected, publicInputs[0]))) >> 32;
        expected = uint256(keccak256(abi.encodePacked(expected, publicInputs[1]))) >> 32;

        assertEq(result, expected);
    }

    function test_computeZKsyncOSHash_withZeroInitialHash() public view {
        uint256 initialHash = 0;
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 100;
        publicInputs[1] = 200;

        uint256 result = verifier.computeZKsyncOSHash(initialHash, publicInputs);

        // When initial hash is 0, it takes the first public input as the starting hash
        uint256 expected = publicInputs[0];
        expected = uint256(keccak256(abi.encodePacked(expected, publicInputs[1]))) >> 32;

        assertEq(result, expected);
    }

    function test_computeZKsyncOSHash_singleInput() public view {
        uint256 initialHash = 12345;
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 100;

        uint256 result = verifier.computeZKsyncOSHash(initialHash, publicInputs);

        uint256 expected = uint256(keccak256(abi.encodePacked(initialHash, publicInputs[0]))) >> 32;

        assertEq(result, expected);
    }

    function test_computeZKsyncOSHash_singleInputWithZeroInitial() public view {
        uint256 initialHash = 0;
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 100;

        uint256 result = verifier.computeZKsyncOSHash(initialHash, publicInputs);

        // When initial is 0 and there's only one input, result is that input
        assertEq(result, publicInputs[0]);
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeZKsyncOSHash_deterministicResults(
        uint256 initialHash,
        uint256 input1,
        uint256 input2
    ) public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = input1;
        publicInputs[1] = input2;

        uint256 result1 = verifier.computeZKsyncOSHash(initialHash, publicInputs);
        uint256 result2 = verifier.computeZKsyncOSHash(initialHash, publicInputs);

        assertEq(result1, result2);
    }

    function testFuzz_verify_revertsOnUnknownType(uint8 verifierType) public {
        vm.assume(verifierType != 2 && verifierType != 3);

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 123;
        publicInputs[1] = 456;

        uint256[] memory proof = new uint256[](4);
        proof[0] = verifierType; // type in lower 8 bits, version 0
        proof[1] = 0;
        proof[2] = 789;
        proof[3] = 101112;

        vm.expectRevert(UnknownVerifierType.selector);
        verifier.verify(publicInputs, proof);
    }
}
