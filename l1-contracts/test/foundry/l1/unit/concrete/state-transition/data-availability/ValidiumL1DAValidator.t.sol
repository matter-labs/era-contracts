// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {L1DAValidatorOutput} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {ValL1DAWrongInputLength} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Unit tests for ValidiumL1DAValidator contract
contract ValidiumL1DAValidatorTest is Test {
    ValidiumL1DAValidator public validator;

    function setUp() public {
        validator = new ValidiumL1DAValidator();
    }

    // ============ checkDA Tests ============

    function test_checkDA_validInput() public {
        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);
        uint256 maxBlobsSupported = 6;

        L1DAValidatorOutput memory output = validator.checkDA(
            1, // chainId
            100, // batchNumber
            bytes32(0), // l2DAValidatorOutputHash (ignored)
            operatorInput,
            maxBlobsSupported
        );

        assertEq(output.stateDiffHash, stateDiffHash);
        assertEq(output.blobsLinearHashes.length, maxBlobsSupported);
        assertEq(output.blobsOpeningCommitments.length, maxBlobsSupported);
    }

    function test_checkDA_blobArraysAreEmpty() public {
        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);
        uint256 maxBlobsSupported = 6;

        L1DAValidatorOutput memory output = validator.checkDA(1, 100, bytes32(0), operatorInput, maxBlobsSupported);

        // All blob hashes should be zero
        for (uint256 i = 0; i < maxBlobsSupported; i++) {
            assertEq(output.blobsLinearHashes[i], bytes32(0));
            assertEq(output.blobsOpeningCommitments[i], bytes32(0));
        }
    }

    function test_checkDA_revertsOnWrongInputLength_tooShort() public {
        bytes memory shortInput = hex"1234"; // Only 2 bytes

        vm.expectRevert(abi.encodeWithSelector(ValL1DAWrongInputLength.selector, 2, 32));
        validator.checkDA(1, 100, bytes32(0), shortInput, 6);
    }

    function test_checkDA_revertsOnWrongInputLength_tooLong() public {
        bytes memory longInput = new bytes(64); // 64 bytes instead of 32

        vm.expectRevert(abi.encodeWithSelector(ValL1DAWrongInputLength.selector, 64, 32));
        validator.checkDA(1, 100, bytes32(0), longInput, 6);
    }

    function test_checkDA_revertsOnEmptyInput() public {
        bytes memory emptyInput = "";

        vm.expectRevert(abi.encodeWithSelector(ValL1DAWrongInputLength.selector, 0, 32));
        validator.checkDA(1, 100, bytes32(0), emptyInput, 6);
    }

    function test_checkDA_ignoresChainIdAndBatchNumber() public {
        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);

        // Different chainId and batchNumber should give same result
        L1DAValidatorOutput memory output1 = validator.checkDA(1, 100, bytes32(0), operatorInput, 6);

        L1DAValidatorOutput memory output2 = validator.checkDA(999, 12345, bytes32(0), operatorInput, 6);

        assertEq(output1.stateDiffHash, output2.stateDiffHash);
    }

    function test_checkDA_ignoresL2DAValidatorOutputHash() public {
        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);

        // Different l2DAValidatorOutputHash should give same result
        L1DAValidatorOutput memory output1 = validator.checkDA(1, 100, bytes32(0), operatorInput, 6);

        L1DAValidatorOutput memory output2 = validator.checkDA(1, 100, keccak256("something"), operatorInput, 6);

        assertEq(output1.stateDiffHash, output2.stateDiffHash);
    }

    function test_checkDA_differentMaxBlobsSupported() public {
        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);

        L1DAValidatorOutput memory output1 = validator.checkDA(1, 100, bytes32(0), operatorInput, 1);
        assertEq(output1.blobsLinearHashes.length, 1);

        L1DAValidatorOutput memory output2 = validator.checkDA(1, 100, bytes32(0), operatorInput, 10);
        assertEq(output2.blobsLinearHashes.length, 10);
    }

    // ============ Fuzz Tests ============

    function testFuzz_checkDA_validStateDiffHash(bytes32 stateDiffHash) public {
        bytes memory operatorInput = abi.encode(stateDiffHash);

        L1DAValidatorOutput memory output = validator.checkDA(1, 100, bytes32(0), operatorInput, 6);

        assertEq(output.stateDiffHash, stateDiffHash);
    }

    function testFuzz_checkDA_anyMaxBlobsSupported(uint8 maxBlobs) public {
        vm.assume(maxBlobs > 0);

        bytes32 stateDiffHash = keccak256("state_diff");
        bytes memory operatorInput = abi.encode(stateDiffHash);

        L1DAValidatorOutput memory output = validator.checkDA(1, 100, bytes32(0), operatorInput, maxBlobs);

        assertEq(output.blobsLinearHashes.length, maxBlobs);
        assertEq(output.blobsOpeningCommitments.length, maxBlobs);
    }

    function testFuzz_checkDA_revertsOnWrongLength(uint8 length) public {
        vm.assume(length != 32);

        bytes memory wrongInput = new bytes(length);

        vm.expectRevert(abi.encodeWithSelector(ValL1DAWrongInputLength.selector, length, 32));
        validator.checkDA(1, 100, bytes32(0), wrongInput, 6);
    }
}
