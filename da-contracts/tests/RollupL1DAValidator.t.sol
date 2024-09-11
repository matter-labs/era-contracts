// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

import {L1DAValidatorOutput} from "../contracts/IL1DAValidator.sol";
import {PubdataSource} from "../contracts/DAUtils.sol";
import {RollupL1DAValidator} from "../contracts/RollupL1DAValidator.sol";
import {PubdataCommitmentsEmpty, InvalidPubdataCommitmentsSize, BlobHashCommitmentError, EmptyBlobVersionHash, NonEmptyBlobVersionHash, PointEvalCallFailed, PointEvalFailed} from "../contracts/DAContractsErrors.sol";

contract RollupL1DAValidatorTest is Test {

    RollupL1DAValidator internal validator;
    bytes pubdataCommitments;

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
        
    }

    function test_checkDAInvalidPubdataSource() public {
        bytes32 stateDiffHash = keccak256(abi.encodePacked(block.timestamp, "stateDiffHash"));
        bytes32 fullPubdataHash = keccak256(abi.encodePacked(block.timestamp, "fullPubdataHash"));
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = keccak256(abi.encodePacked(block.timestamp, "blobLinearHash"));

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes memory l1DaInput = "verifydonttrust";

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, l1DaInput);
        
        vm.expectRevert("l1-da-validator/invalid-pubdata-source");
        validator.checkDA(0, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_checkDA() public {
        bytes memory pubdata = "verifydont";

        bytes32 stateDiffHash = keccak256(abi.encodePacked(block.timestamp, "stateDiffHash"));
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = keccak256(abi.encodePacked(block.timestamp, "blobLinearHash"));
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verify dont trust zk is the end game magic moon math";
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
}