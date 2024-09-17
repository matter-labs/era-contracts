// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";
import "forge-std/console.sol";
import {L1DAValidatorOutput} from "../contracts/IL1DAValidator.sol";
import {PubdataSource} from "../contracts/DAUtils.sol";
import {RollupL1DAValidator} from "../contracts/RollupL1DAValidator.sol";
import {DummyRollupL1DAValidator} from "./DummyRollupL1DAValidator.sol";
import {PubdataCommitmentsEmpty, InvalidPubdataCommitmentsSize, BlobHashCommitmentError, EmptyBlobVersionHash, NonEmptyBlobVersionHash, PointEvalCallFailed, PointEvalFailed} from "../contracts/DAContractsErrors.sol";
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

    // function test_publishBlobs(bytes32 blobCommitment) public {
    //     bytes32[] memory blobCommitments = new bytes32[](1);
    //     blobCommitments[0] = blobCommitment;

    //     vm.blobhashes(blobCommitments);

    //     pubdataCommitments = Utils.getDefaultBlobCommitment();

    //     validator.publishBlobs(pubdataCommitments);
    // }

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

    // function test_getPublishedBlobCommitment(bytes32 blobCommitment) public {
    //     bytes32[] memory blobCommitments = new bytes32[](1);
    //     blobCommitments[0] = blobCommitment;

    //     vm.blobhashes(blobCommitments);

    //     uint256 index = 0;
    //     bytes memory commitment = Utils.getDefaultBlobCommitment();

    //     dummyValidator.getPublishedBlobCommitment(index, commitment);
    // }

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

    function test_processBlobDANonEmptyBlobVersionHash(bytes32 blobCommitment) public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
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

        bytes32[] memory blobsCommitments = dummyValidator.processBlobDA(blobsProvided, maxBlobsSupported, operatorDAInput);

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
        bytes32 versionedHash = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        bytes32 openingPoint = bytes32(uint256(uint128(0x7142c5851421a2dc03dde0aabdb0ffdb)));
        bytes memory openingValueCommitmentProof = abi.encodePacked(
            bytes32(0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0),
            hex"ad5a32c9486ad7ab553916b36b742ed89daffd4538d95f4fc8a6c5c07d11f4102e34b3c579d9b4eb6c295a78e484d3bf",
            hex"b7565b1cf204d9f35cec98a582b8a15a1adff6d21f3a3a6eb6af5a91f0a385c069b34feb70bea141038dc7faca5ed364"
        );

        bytes32[] memory blobCommitments = new bytes32[](1);
        blobCommitments[0] = versionedHash;
        vm.blobhashes(blobCommitments);

        dummyValidator.dummyPublishBlobs(versionedHash);

        console.log(abi.encodePacked(versionedHash, openingPoint, openingValueCommitmentProof).length);

        dummyValidator.pointEvaluationPrecompile(versionedHash, openingPoint, openingValueCommitmentProof);
    }

    // function test_pointEvaluationPrecompile() public {
    //     bytes32 versionedHash = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
    //     bytes32 openingPoint = bytes32(uint256(uint128(0x7142c5851421a2dc03dde0aabdb0ffdb)));
    //     bytes memory openingValueCommitmentProof = abi.encodePacked(
    //         bytes32(0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0),
    //         hex"ad5a32c9486ad7ab553916b36b742ed89daffd4538d95f4fc8a6c5c07d11f4102e34b3c579d9b4eb6c295a78e484d3bf",
    //         hex"b7565b1cf204d9f35cec98a582b8a15a1adff6d21f3a3a6eb6af5a91f0a385c069b34feb70bea141038dc7faca5ed364"
    //     );
        
    //     dummyValidator.pointEvaluationPrecompile(versionedHash, openingPoint, openingValueCommitmentProof);
    // }

    function test_getBlobVersionedHash(uint256 index) public {
        bytes32 versionedHash;
        bytes32 expected = dummyValidator.getBlobVersionedHash(index);
        assembly {
            versionedHash := blobhash(index)
        }

        assertEq(expected, versionedHash, "Invalid blob version hash");
    }
}
