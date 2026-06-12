// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZKsyncOSVerifierFri} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFri.sol";
import {
    EmptyProofLength,
    EmptyPublicInputsLength,
    InvalidProof,
    InvalidProofFormat
} from "contracts/common/L1ContractErrors.sol";
import {ZKSYNC_OS_FRI_PRECOMPILE_ADDR, ZKSYNC_OS_FRI_STATEMENT_HASH_VERSION} from "contracts/common/Config.sol";

contract ZKsyncOSVerifierFriTest is Test {
    ZKsyncOSVerifierFri internal verifier;

    address internal constant FRI_PRECOMPILE_ADDR = ZKSYNC_OS_FRI_PRECOMPILE_ADDR;
    uint8 internal constant FRI_STATEMENT_HASH_VERSION = ZKSYNC_OS_FRI_STATEMENT_HASH_VERSION;

    bytes32 internal constant PUBLIC_INPUT_HASH = 0xf8bf9c0063d60a4ad23ee001554fa8de9e4022e0c9c7633b64b693af43808b94;
    bytes32 internal constant RECURSION_CHAIN_HASH = 0x5476c643939eb00bdcffd3857c31a15f0a213407e4f1807dc69e64cde11c403b;
    bytes32 internal constant DIFFERENT_RECURSION_CHAIN_HASH =
        0x1111111111111111111111111111111111111111111111111111111111111111;

    function setUp() public {
        verifier = new ZKsyncOSVerifierFri(RECURSION_CHAIN_HASH);
    }

    function test_verificationKeyHash() public view {
        assertEq(verifier.verificationKeyHash(), RECURSION_CHAIN_HASH);
    }

    function test_computeStatementVersionedHash() public view {
        bytes32 rawHash = keccak256(abi.encodePacked(PUBLIC_INPUT_HASH, RECURSION_CHAIN_HASH));
        bytes32 expected = bytes32(
            (uint256(rawHash) & ((1 << 248) - 1)) | (uint256(FRI_STATEMENT_HASH_VERSION) << 248)
        );

        assertEq(verifier.computeStatementVersionedHash(PUBLIC_INPUT_HASH), expected);
        assertEq(uint8(expected[0]), FRI_STATEMENT_HASH_VERSION);
    }

    function test_computeStatementVersionedHash_dependsOnStoredRecursionHash() public {
        ZKsyncOSVerifierFri otherVerifier = new ZKsyncOSVerifierFri(DIFFERENT_RECURSION_CHAIN_HASH);

        assertNotEq(
            verifier.computeStatementVersionedHash(PUBLIC_INPUT_HASH),
            otherVerifier.computeStatementVersionedHash(PUBLIC_INPUT_HASH)
        );
    }

    function test_computeZKsyncOSHash_singlePublicInput() public view {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(PUBLIC_INPUT_HASH) >> 32;

        assertEq(verifier.computeZKsyncOSHash(0, publicInputs), uint256(PUBLIC_INPUT_HASH) >> 32);
    }

    function test_computeZKsyncOSHash_multiplePublicInputs() public view {
        uint256[] memory publicInputs = new uint256[](3);
        publicInputs[0] = 11;
        publicInputs[1] = 22;
        publicInputs[2] = 33;

        uint256 expected = uint256(keccak256(abi.encodePacked(publicInputs[0], publicInputs[1]))) >> 32;
        expected = uint256(keccak256(abi.encodePacked(expected, publicInputs[2]))) >> 32;

        assertEq(verifier.computeZKsyncOSHash(0, publicInputs), expected);
    }

    function test_computeZKsyncOSHash_twoPublicInputs() public view {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = 11;
        publicInputs[1] = 22;

        uint256 expected = uint256(keccak256(abi.encodePacked(publicInputs[0], publicInputs[1]))) >> 32;

        assertEq(verifier.computeZKsyncOSHash(0, publicInputs), expected);
    }

    function test_computeZKsyncOSHash_emptyInputsWithInitialHash() public view {
        uint256 initialHash = 12345;
        uint256[] memory publicInputs = new uint256[](0);

        assertEq(verifier.computeZKsyncOSHash(initialHash, publicInputs), initialHash);
    }

    function test_computeZKsyncOSHash_revertsOnEmptyInputsWithoutInitialHash() public {
        uint256[] memory publicInputs = new uint256[](0);

        vm.expectRevert(EmptyPublicInputsLength.selector);
        verifier.computeZKsyncOSHash(0, publicInputs);
    }

    function test_verify_returnsTrueWhenPrecompileReturnsTrue() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCall(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), abi.encode(true));

        assertTrue(verifier.verify(publicInputs, proof));
    }

    function test_verify_returnsFalseWhenPrecompileReturnsFalse() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCall(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), abi.encode(false));

        assertFalse(verifier.verify(publicInputs, proof));
    }

    function test_verify_revertsWhenPrecompileReverts() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCallRevert(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), "");

        vm.expectRevert(InvalidProof.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsWhenPrecompileReturnsShortData() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCall(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), hex"01");

        vm.expectRevert(InvalidProof.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsWhenPrecompileReturnsNonBooleanWord() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCall(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), abi.encode(uint256(2)));

        vm.expectRevert(InvalidProof.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsWhenPrecompileReturnsLongData() public {
        (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash) = _validInputs();

        vm.mockCall(FRI_PRECOMPILE_ADDR, abi.encodePacked(statementHash), abi.encode(uint256(1), uint256(1)));

        vm.expectRevert(InvalidProof.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnEmptyPublicInputs() public {
        uint256[] memory publicInputs = new uint256[](0);
        uint256[] memory proof = _validProof();

        vm.expectRevert(EmptyPublicInputsLength.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnMultiplePublicInputs() public {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(PUBLIC_INPUT_HASH) >> 32;
        publicInputs[1] = 1;
        uint256[] memory proof = _validProof();

        vm.expectRevert(InvalidProofFormat.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnEmptyProof() public {
        uint256[] memory publicInputs = _validPublicInputs();
        uint256[] memory proof = new uint256[](0);

        vm.expectRevert(EmptyProofLength.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnInvalidProofLength() public {
        uint256[] memory publicInputs = _validPublicInputs();
        uint256[] memory proof = new uint256[](2);
        proof[0] = uint256(PUBLIC_INPUT_HASH);
        proof[1] = uint256(RECURSION_CHAIN_HASH);

        vm.expectRevert(InvalidProofFormat.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnProofLengthGreaterThanOne() public {
        uint256[] memory publicInputs = _validPublicInputs();
        uint256[] memory proof = new uint256[](3);
        proof[0] = uint256(PUBLIC_INPUT_HASH);
        proof[1] = uint256(RECURSION_CHAIN_HASH);
        proof[2] = 1;

        vm.expectRevert(InvalidProofFormat.selector);
        verifier.verify(publicInputs, proof);
    }

    function test_verify_revertsOnPublicInputHashMismatch() public {
        uint256[] memory publicInputs = _validPublicInputs();
        uint256[] memory proof = _validProof();
        proof[0] = uint256(bytes32(uint256(PUBLIC_INPUT_HASH) + 1));

        vm.expectRevert(InvalidProof.selector);
        verifier.verify(publicInputs, proof);
    }

    function testFuzz_verify_rejectsWrongProofLength(uint8 proofLength) public {
        vm.assume(proofLength != 1);

        uint256[] memory publicInputs = _validPublicInputs();
        uint256[] memory proof = new uint256[](proofLength);

        if (proofLength == 0) {
            vm.expectRevert(EmptyProofLength.selector);
        } else {
            vm.expectRevert(InvalidProofFormat.selector);
        }
        verifier.verify(publicInputs, proof);
    }

    function _validInputs()
        internal
        view
        returns (uint256[] memory publicInputs, uint256[] memory proof, bytes32 statementHash)
    {
        publicInputs = _validPublicInputs();
        proof = _validProof();
        statementHash = verifier.computeStatementVersionedHash(PUBLIC_INPUT_HASH);
    }

    function _validPublicInputs() internal pure returns (uint256[] memory publicInputs) {
        publicInputs = new uint256[](1);
        publicInputs[0] = uint256(PUBLIC_INPUT_HASH) >> 32;
    }

    function _validProof() internal pure returns (uint256[] memory proof) {
        proof = new uint256[](1);
        proof[0] = uint256(PUBLIC_INPUT_HASH);
    }
}
