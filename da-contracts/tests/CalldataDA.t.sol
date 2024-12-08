// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

import {DummyCalldataDA} from "./DummyCalldataDA.sol";
import {Utils} from "./Utils.sol";

contract CalldataDATest is Test {
    DummyCalldataDA internal dummyCalldata;
    uint256 constant BLOB_SIZE_BYTES = 126_976;
    bytes32 constant EMPTY_PREPUBLISHED_COMMITMENT = 0x0000000000000000000000000000000000000000000000000000000000000000;

    function setUp() public {
        dummyCalldata = new DummyCalldataDA();
    }

    function test_processL2RollupDAValidatorOutputHashTooSmall() public {
        bytes32 l2DAValidatorOutputHash = 0;
        uint256 maxBlobsSupported = 0;
        bytes memory operatorDAInput = bytes("");

        vm.expectRevert("too small");
        dummyCalldata.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_processL2RollupDAValidatorOutputHashInvalidNumberOfBlobs() public {
        bytes32 l2DAValidatorOutputHash = 0;
        uint256 maxBlobsSupported = 0;

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        vm.expectRevert("invalid number of blobs");
        dummyCalldata.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_processL2RollupDAValidatorOutputHashInvalidBlobsHashes() public {
        bytes32 l2DAValidatorOutputHash = 0;
        uint256 maxBlobsSupported = 2;

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 10;
        bytes32[] memory blobsLinearHashes;

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        vm.expectRevert("invalid number of blobs");
        dummyCalldata.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_processL2RollupDAValidatorOutputHashInvalidL2DAOutputHash() public {
        bytes32 l2DAValidatorOutputHash = 0;
        uint256 maxBlobsSupported = 2;

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        vm.expectRevert("invalid l2 DA output hash");
        dummyCalldata.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_processL2RollupDAValidatorOutputHash() public {
        bytes32 l2DAValidatorOutputHash = 0x9ae4f54d24da2acb0e28b3caccac44ebce8caa847d0b0ebdfe541ee3772f54b4;
        uint256 maxBlobsSupported = 2;

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        bytes32 stateDiffHash;
        bytes32 fullPubdataHash;
        bytes32[] memory blobsLinearHash;
        uint256 blobsProvided;
        bytes memory l1DaInput;

        (stateDiffHash, fullPubdataHash, blobsLinearHash, blobsProvided, l1DaInput) = dummyCalldata
            .processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);

        bytes memory expectedl1DaInput = abi.encodePacked(source, defaultBlobCommitment, EMPTY_PREPUBLISHED_COMMITMENT);

        assertEq(uncompressedStateDiffHash, stateDiffHash, "Invalid state diff hash");
        assertEq(totalL2PubdataHash, fullPubdataHash, "Invalid full pubdata hash");
        assertEq(blobsLinearHashes[0], blobsLinearHash[0], "Invalid blobs linear hash");
        assertEq(numberOfBlobs, blobsProvided, "Invalid blobs provided");
        assertEq(expectedl1DaInput, l1DaInput, "Invalid l1 DA input");
    }

    function test_processCalldataDAOneBlobWithCalldata() public {
        uint256 blobsProvided = 2;
        bytes32 fullPubdataHash;
        uint256 maxBlobsSupported;
        bytes memory pubdataInput;

        vm.expectRevert("one blob with calldata");
        dummyCalldata.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_processCalldataDAPubdataTooSmall() public {
        uint256 blobsProvided = 1;
        bytes32 fullPubdataHash;
        uint256 maxBlobsSupported;
        bytes memory pubdataInput;

        vm.expectRevert("pubdata too small");
        dummyCalldata.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_processCalldataDAInvalidPubdataLength() public {
        uint256 blobsProvided = 1;
        bytes32 fullPubdataHash;
        uint256 maxBlobsSupported;
        bytes memory pubdataInput = Utils.makeBytesArrayOfLength(BLOB_SIZE_BYTES + 33);

        vm.expectRevert(bytes("cz"));
        dummyCalldata.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_processCalldataDAInvalidPubdataHash() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes memory pubdataInputWithoutBlobCommitment = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 blobCommitment = Utils.randomBytes32("blobCommitment");
        bytes memory pubdataInput = abi.encodePacked(pubdataInputWithoutBlobCommitment, blobCommitment);
        bytes32 fullPubdataHash = keccak256(pubdataInput);

        vm.expectRevert(bytes("wp"));
        dummyCalldata.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_processCalldataDA() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes memory pubdataInputWithoutBlobCommitment = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 blobCommitment = Utils.randomBytes32("blobCommitment");
        bytes memory pubdataInput = abi.encodePacked(pubdataInputWithoutBlobCommitment, blobCommitment);
        bytes32 fullPubdataHash = keccak256(pubdataInputWithoutBlobCommitment);

        (bytes32[] memory blobCommitments, bytes memory pubdata) = dummyCalldata.processCalldataDA(
            blobsProvided,
            fullPubdataHash,
            maxBlobsSupported,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6, "Invalid blob Commitment length");
        assertEq(blobCommitments[0], blobCommitment, "Invalid blob Commitment 1");
        assertEq(blobCommitments[1], bytes32(0), "Invalid blob Commitment 2");
        assertEq(blobCommitments[2], bytes32(0), "Invalid blob Commitment 3");
        assertEq(blobCommitments[3], bytes32(0), "Invalid blob Commitment 4");
        assertEq(blobCommitments[4], bytes32(0), "Invalid blob Commitment 5");
        assertEq(blobCommitments[5], bytes32(0), "Invalid blob Commitment 6");
        assertEq(pubdata, pubdataInputWithoutBlobCommitment, "Invalid pubdata");
    }
}
