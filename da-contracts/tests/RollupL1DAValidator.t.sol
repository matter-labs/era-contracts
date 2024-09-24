// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

import {L1DAValidatorOutput} from "../contracts/IL1DAValidator.sol";
import {PubdataSource} from "../contracts/DAUtils.sol";
import {RollupL1DAValidator} from "../contracts/RollupL1DAValidator.sol";
import {DummyRollupL1DAValidator} from "./DummyRollupL1DAValidator.sol";
import {PubdataCommitmentsEmpty, InvalidPubdataCommitmentsSize, BlobHashCommitmentError, EmptyBlobVersionHash, NonEmptyBlobVersionHash, PointEvalCallFailed, PointEvalFailed} from "../contracts/DAContractsErrors.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "../contracts/DAUtils.sol";
import {Utils} from "./Utils.sol";

contract RollupL1DAValidatorTest is Test {
    RollupL1DAValidator internal validator;
    DummyRollupL1DAValidator internal dummyValidator;
    bytes pubdataCommitments;

    function setUp() public {
        validator = new RollupL1DAValidator();
        dummyValidator = new DummyRollupL1DAValidator();
    }

    function test_publishBlobsPubdataCommitmentsEmpty() public {
        vm.expectRevert(PubdataCommitmentsEmpty.selector);
        validator.publishBlobs(pubdataCommitments);
    }

    function test_publishBlobsInvalidPubdataCommitmentsSize() public {
        pubdataCommitments = bytes("2");

        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        validator.publishBlobs(pubdataCommitments);
    }

    function test_publishBlobs() public {
        bytes32 blobCommitment = Utils.randomBytes32("Blob Commitment");
        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = blobCommitment;

        vm.blobhashes(blobCommitments);

        pubdataCommitments = Utils.getDefaultBlobCommitmentForPointEval();

        dummyValidator.dummyPublishBlobsTest(pubdataCommitments);
    }

    function test_checkDAInvalidPubdataSource() public {
        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes memory l1DaInput = "verifydonttrust";

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, l1DaInput);

        vm.expectRevert("l1-da-validator/invalid-pubdata-source");
        validator.checkDA(0, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_checkDABlobHashCommitmentError() public {
        bytes memory pubdata = "verifydont";

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = 0;
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 fullPubdataHash = keccak256(pubdata);

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes32 l2DAValidatorOutputHash = keccak256(daInput);
        bytes memory operatorDAInput = abi.encodePacked(daInput, pubdataSource, l1DaInput);

        vm.expectRevert(abi.encodeWithSelector(BlobHashCommitmentError.selector, 0, true, false));
        validator.checkDA(0, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_checkDA() public {
        bytes memory pubdata = "verifydont";

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 fullPubdataHash = keccak256(pubdata);

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes32 l2DAValidatorOutputHash = keccak256(daInput);
        bytes memory operatorDAInput = abi.encodePacked(daInput, pubdataSource, l1DaInput);

        L1DAValidatorOutput memory output = validator.checkDA(
            0,
            0,
            l2DAValidatorOutputHash,
            operatorDAInput,
            maxBlobsSupported
        );
        assertEq(output.stateDiffHash, stateDiffHash, "stateDiffHash");
        assertEq(output.blobsLinearHashes.length, maxBlobsSupported, "blobsLinearHashesLength");
        assertEq(output.blobsOpeningCommitments.length, maxBlobsSupported, "blobsOpeningCommitmentsLength");
    }

    function test_getPublishedBlobCommitmentEmptyBlobVersionHash() public {
        uint256 index = 0;
        bytes memory commitment = bytes("");

        vm.expectRevert(abi.encodeWithSelector(EmptyBlobVersionHash.selector, index));
        dummyValidator.getPublishedBlobCommitment(index, commitment);
    }

    function test_getPublishedBlobCommitment() public {
        bytes32 blobCommitment = Utils.randomBytes32("Blob Commitment");
        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = blobCommitment;

        vm.blobhashes(blobCommitments);

        uint256 index = 0;
        bytes memory commitment = Utils.getDefaultBlobCommitmentForPointEval();

        dummyValidator.dummyGetPublishedBlobCommitment(index, commitment);
    }

    function test_processBlobDAInvalidPubdataCommitmentsSize() public {
        uint256 blobsProvided = 0;
        uint256 maxBlobsSupported = 6;
        bytes memory operatorDAInput = bytes("1234");

        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        dummyValidator.processBlobDA(blobsProvided, maxBlobsSupported, operatorDAInput);
    }

    function test_processBlobDANotPublished() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
        blobsLinearHashes[1] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            blobsProvided,
            blobsLinearHashes,
            bytes16("")
        );

        vm.expectRevert("not published");
        dummyValidator.processBlobDA(blobsProvided, maxBlobsSupported, operatorDAInput);
    }

    function test_processBlobDANonEmptyBlobVersionHash() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
        blobsLinearHashes[1] = Utils.randomBytes32("blobsLinearHashes");
        bytes32 blobCommitment = Utils.randomBytes32("commit");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            blobsProvided,
            blobsLinearHashes,
            bytes16(""),
            totalL2PubdataHash
        );

        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = blobCommitment;
        vm.blobhashes(blobCommitments);

        dummyValidator.dummyPublishBlobs(totalL2PubdataHash);

        vm.expectRevert(abi.encodeWithSelector(NonEmptyBlobVersionHash.selector, 0));
        dummyValidator.processBlobDA(blobsProvided, maxBlobsSupported, operatorDAInput);
    }

    function test_processBlobDA() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");
        blobsLinearHashes[1] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            blobsProvided,
            blobsLinearHashes,
            bytes16(""),
            totalL2PubdataHash
        );

        dummyValidator.dummyPublishBlobs(totalL2PubdataHash);

        bytes32[] memory blobsCommitments = dummyValidator.processBlobDA(
            blobsProvided,
            maxBlobsSupported,
            operatorDAInput
        );

        assertEq(blobsCommitments.length, maxBlobsSupported, "Invalid commitment length");
        assertEq(blobsCommitments[0], totalL2PubdataHash, "Invalid commitment 1");
    }

    function test_pointEvaluationPrecompilePointEvalCallFailed() public {
        bytes32 versionedHash = 0;
        bytes32 openingPoint = 0;
        bytes memory openingValueCommitmentProof = bytes("");
        bytes memory precompileInput = abi.encodePacked(versionedHash, openingPoint, openingValueCommitmentProof);

        vm.expectRevert(abi.encodeWithSelector(PointEvalCallFailed.selector, precompileInput));
        dummyValidator.pointEvaluationPrecompile(versionedHash, openingPoint, openingValueCommitmentProof);
    }

    function test_pointEvaluationPrecompilePointEvalFailed() public {
        bytes
            memory commitment = hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        bytes32 openingPoint = 0x564c0a11a0f704f4fc3e8acfe0f8245f0ad1347b378fbf96e206da11a5d36306;
        bytes memory openingValueCommitmentProof = abi.encodePacked(
            bytes32(0x0000000000000000000000000000000000000000000000000000000000000002),
            hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e",
            hex"c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );

        bytes32 versionedHash = kzgToVersionHash(commitment);

        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = versionedHash;
        vm.blobhashes(blobCommitments);

        dummyValidator.dummyPublishBlobs(versionedHash);

        bytes
            memory POINT_EVALUATION_PRECOMPILE_RESULT = hex"000000000000000000000000000000000000000000000000000000000000120073eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff021a0003";

        bytes memory data = POINT_EVALUATION_PRECOMPILE_RESULT;
        (, uint256 result) = abi.decode(data, (uint256, uint256));

        vm.expectRevert(abi.encodeWithSelector(PointEvalFailed.selector, abi.encode(result)));
        dummyValidator.mockPointEvaluationPrecompile(versionedHash, openingPoint, openingValueCommitmentProof);
    }

    function test_pointEvaluationPrecompile() public {
        bytes
            memory commitment = hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        bytes32 openingPoint = 0x564c0a11a0f704f4fc3e8acfe0f8245f0ad1347b378fbf96e206da11a5d36306;
        bytes memory openingValueCommitmentProof = abi.encodePacked(
            bytes32(0x0000000000000000000000000000000000000000000000000000000000000002),
            hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e",
            hex"c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );

        bytes32 versionedHash = kzgToVersionHash(commitment);

        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = versionedHash;
        vm.blobhashes(blobCommitments);

        dummyValidator.dummyPublishBlobs(versionedHash);

        dummyValidator.pointEvaluationPrecompile(versionedHash, openingPoint, openingValueCommitmentProof);
    }

    function test_getBlobVersionedHash(uint256 index) public {
        bytes32 versionedHash;
        bytes32 expected = dummyValidator.getBlobVersionedHash(index);
        assembly {
            versionedHash := blobhash(index)
        }

        assertEq(expected, versionedHash, "Invalid blob version hash");
    }
}

function kzgToVersionHash(bytes memory commitment) returns (bytes32 versionHash) {
    bytes memory versionedHash = new bytes(32);
    bytes32 commitmentHash = sha256(commitment);

    versionedHash[0] = 0x01;
    for (uint8 i = 1; i < 32; i++) {
        versionedHash[i] = commitmentHash[i];
    }

    for (uint i = 0; i < 32; i++) {
        versionHash |= bytes32(versionedHash[i] & 0xFF) >> (i * 8);
    }
}
