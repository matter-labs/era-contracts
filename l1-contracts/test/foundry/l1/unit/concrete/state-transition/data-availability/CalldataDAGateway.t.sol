// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CalldataDAGateway, BLOB_COMMITMENT_SIZE, BLOB_SIZE_BYTES} from "contracts/state-transition/data-availability/CalldataDAGateway.sol";
import {InvalidPubdataHash, PubdataInputTooSmall, PubdataLengthTooBig} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Concrete implementation of CalldataDAGateway for testing
contract CalldataDAGatewayHarness is CalldataDAGateway {
    /// @notice External wrapper for testing _processCalldataDA
    function processCalldataDA(
        uint256 _blobsProvided,
        bytes32 _fullPubdataHash,
        uint256 _maxBlobsSupported,
        bytes calldata _pubdataInput
    ) external pure returns (bytes32[] memory blobCommitments, bytes memory pubdata) {
        bytes calldata pubdataCalldata;
        (blobCommitments, pubdataCalldata) = _processCalldataDA(
            _blobsProvided,
            _fullPubdataHash,
            _maxBlobsSupported,
            _pubdataInput
        );
        pubdata = pubdataCalldata;
    }
}

/// @notice Unit tests for CalldataDAGateway contract
contract CalldataDAGatewayTest is Test {
    CalldataDAGatewayHarness public gateway;

    function setUp() public {
        gateway = new CalldataDAGatewayHarness();
    }

    // ============ _processCalldataDA Tests ============

    function test_processCalldataDA_validSingleBlob() public view {
        bytes memory pubdata = "test pubdata content";
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            1, // blobsProvided
            pubdataHash,
            6, // maxBlobsSupported
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(blobCommitments[0], commitment);
        assertEq(keccak256(returnedPubdata), pubdataHash);
    }

    function test_processCalldataDA_multipleBlobs() public view {
        bytes memory pubdata = "test pubdata content";
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment1 = keccak256("commitment1");
        bytes32 commitment2 = keccak256("commitment2");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment1, commitment2);

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            2, // blobsProvided
            pubdataHash,
            6, // maxBlobsSupported
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(blobCommitments[0], commitment1);
        assertEq(blobCommitments[1], commitment2);
        assertEq(keccak256(returnedPubdata), pubdataHash);
    }

    function test_processCalldataDA_emptyPubdata() public view {
        bytes memory pubdata = "";
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            1,
            pubdataHash,
            6,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(blobCommitments[0], commitment);
        assertEq(returnedPubdata.length, 0);
    }

    function test_processCalldataDA_revertsOnInputTooSmall() public {
        bytes memory pubdataInput = new bytes(31); // Less than BLOB_COMMITMENT_SIZE

        vm.expectRevert(abi.encodeWithSelector(PubdataInputTooSmall.selector, 31, 32));
        gateway.processCalldataDA(1, bytes32(0), 6, pubdataInput);
    }

    function test_processCalldataDA_revertsOnInputTooSmallForMultipleBlobs() public {
        bytes memory pubdataInput = new bytes(50); // Less than 2 * BLOB_COMMITMENT_SIZE = 64

        vm.expectRevert(abi.encodeWithSelector(PubdataInputTooSmall.selector, 50, 64));
        gateway.processCalldataDA(2, bytes32(0), 6, pubdataInput);
    }

    function test_processCalldataDA_revertsOnPubdataTooLarge() public {
        // Create pubdata larger than BLOB_SIZE_BYTES * blobsProvided
        bytes memory largePubdata = new bytes(BLOB_SIZE_BYTES + 1);
        bytes32 pubdataHash = keccak256(largePubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(largePubdata, commitment);

        vm.expectRevert(abi.encodeWithSelector(PubdataLengthTooBig.selector, BLOB_SIZE_BYTES + 1, BLOB_SIZE_BYTES));
        gateway.processCalldataDA(1, pubdataHash, 6, pubdataInput);
    }

    function test_processCalldataDA_revertsOnPubdataTooLargeForMultipleBlobs() public {
        // Create pubdata larger than BLOB_SIZE_BYTES * 2
        bytes memory largePubdata = new bytes(BLOB_SIZE_BYTES * 2 + 1);
        bytes32 pubdataHash = keccak256(largePubdata);
        bytes32 commitment1 = keccak256("commitment1");
        bytes32 commitment2 = keccak256("commitment2");

        bytes memory pubdataInput = abi.encodePacked(largePubdata, commitment1, commitment2);

        vm.expectRevert(
            abi.encodeWithSelector(PubdataLengthTooBig.selector, BLOB_SIZE_BYTES * 2 + 1, BLOB_SIZE_BYTES * 2)
        );
        gateway.processCalldataDA(2, pubdataHash, 6, pubdataInput);
    }

    function test_processCalldataDA_revertsOnInvalidPubdataHash() public {
        bytes memory pubdata = "test pubdata content";
        bytes32 wrongHash = keccak256("wrong hash");
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataHash.selector, wrongHash, keccak256(pubdata)));
        gateway.processCalldataDA(1, wrongHash, 6, pubdataInput);
    }

    function test_processCalldataDA_exactMaxBlobSize() public view {
        // Create pubdata exactly at BLOB_SIZE_BYTES
        bytes memory pubdata = new bytes(BLOB_SIZE_BYTES);
        for (uint256 i = 0; i < BLOB_SIZE_BYTES; i++) {
            pubdata[i] = bytes1(uint8(i % 256));
        }
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            1,
            pubdataHash,
            6,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(returnedPubdata.length, BLOB_SIZE_BYTES);
    }

    function test_processCalldataDA_zeroBlobs() public view {
        bytes memory pubdata = "";
        bytes32 pubdataHash = keccak256(pubdata);

        bytes memory pubdataInput = pubdata;

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            0, // 0 blobs provided
            pubdataHash,
            6,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(returnedPubdata.length, 0);
    }

    function test_processCalldataDA_commitmentsAreCopiedCorrectly() public view {
        bytes memory pubdata = "test";
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment1 = bytes32(uint256(1));
        bytes32 commitment2 = bytes32(uint256(2));
        bytes32 commitment3 = bytes32(uint256(3));

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment1, commitment2, commitment3);

        (bytes32[] memory blobCommitments, ) = gateway.processCalldataDA(3, pubdataHash, 6, pubdataInput);

        assertEq(blobCommitments[0], commitment1);
        assertEq(blobCommitments[1], commitment2);
        assertEq(blobCommitments[2], commitment3);
        // Rest should be zero
        assertEq(blobCommitments[3], bytes32(0));
        assertEq(blobCommitments[4], bytes32(0));
        assertEq(blobCommitments[5], bytes32(0));
    }

    function test_processCalldataDA_differentMaxBlobsSupported() public view {
        bytes memory pubdata = "test";
        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments1, ) = gateway.processCalldataDA(1, pubdataHash, 1, pubdataInput);
        assertEq(blobCommitments1.length, 1);

        (bytes32[] memory blobCommitments10, ) = gateway.processCalldataDA(1, pubdataHash, 10, pubdataInput);
        assertEq(blobCommitments10.length, 10);
    }

    // ============ Fuzz Tests ============

    function testFuzz_processCalldataDA_validInput(bytes memory pubdata) public view {
        vm.assume(pubdata.length <= BLOB_SIZE_BYTES);

        bytes32 pubdataHash = keccak256(pubdata);
        bytes32 commitment = keccak256("commitment");

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments, bytes memory returnedPubdata) = gateway.processCalldataDA(
            1,
            pubdataHash,
            6,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6);
        assertEq(blobCommitments[0], commitment);
        assertEq(keccak256(returnedPubdata), pubdataHash);
    }

    function testFuzz_processCalldataDA_revertsOnWrongHash(bytes memory pubdata, bytes32 wrongHash) public {
        vm.assume(pubdata.length <= BLOB_SIZE_BYTES);
        vm.assume(keccak256(pubdata) != wrongHash);

        bytes32 commitment = keccak256("commitment");
        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataHash.selector, wrongHash, keccak256(pubdata)));
        gateway.processCalldataDA(1, wrongHash, 6, pubdataInput);
    }

    function testFuzz_processCalldataDA_anyCommitment(bytes32 commitment) public view {
        bytes memory pubdata = "test pubdata";
        bytes32 pubdataHash = keccak256(pubdata);

        bytes memory pubdataInput = abi.encodePacked(pubdata, commitment);

        (bytes32[] memory blobCommitments, ) = gateway.processCalldataDA(1, pubdataHash, 6, pubdataInput);

        assertEq(blobCommitments[0], commitment);
    }

    function testFuzz_processCalldataDA_revertsOnInputTooSmall(uint8 inputLength, uint8 blobsProvided) public {
        vm.assume(blobsProvided > 0 && blobsProvided <= 6); // Reasonable blob limit
        uint256 requiredSize = uint256(BLOB_COMMITMENT_SIZE) * uint256(blobsProvided);
        vm.assume(inputLength < requiredSize);

        bytes memory pubdataInput = new bytes(inputLength);

        vm.expectRevert(abi.encodeWithSelector(PubdataInputTooSmall.selector, inputLength, requiredSize));
        gateway.processCalldataDA(blobsProvided, bytes32(0), 6, pubdataInput);
    }
}
