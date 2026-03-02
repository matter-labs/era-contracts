// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockBlobsL1DAValidator} from "./MockBlobsL1DAValidator.sol";
import {BLOB_EXPIRATION_BLOCKS} from "../../contracts/BlobsL1DAValidatorZKsyncOS.sol";
import {
    InvalidBlobsPublished,
    InvalidBlobsDAInputLength,
    BlobNotPublished,
    NonEmptyBlobVersionHash
} from "../../contracts/DAContractsErrors.sol";
import {L1DAValidatorOutput} from "../../contracts/IL1DAValidator.sol";

contract BlobsL1DAValidatorZKsyncOSTest is Test {
    MockBlobsL1DAValidator internal validator;

    function setUp() public {
        validator = new MockBlobsL1DAValidator();
    }

    function testPublishBlobsStoresHashes() public {
        bytes32[] memory blobs = new bytes32[](2);
        blobs[0] = keccak256("blob1");
        blobs[1] = keccak256("blob2");
        validator.setMockBlobs(blobs);

        validator.publishBlobs();

        assertEq(validator.publishedBlobs(blobs[0]), block.number);
        assertEq(validator.publishedBlobs(blobs[1]), block.number);
        assertEq(validator.publishedBlobs(keccak256("nonexistent")), 0);
    }

    function testIsBlobAvailable() public {
        bytes32 blobHash = keccak256("blob");
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = blobHash;
        validator.setMockBlobs(blobs);

        validator.publishBlobs();
        assertTrue(validator.isBlobAvailable(blobHash));

        // Move far into the future past expiration
        vm.roll(block.number + BLOB_EXPIRATION_BLOCKS + 1);
        assertFalse(validator.isBlobAvailable(blobHash));
    }

    function testCheckDAInvalidLength() public {
        bytes memory badInput = hex"1234"; // not multiple of 32
        vm.expectRevert(abi.encodeWithSelector(InvalidBlobsDAInputLength.selector, 2));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, bytes32(0), badInput, 0);
    }

    function testCheckDABlobNotPublished() public {
        bytes32 notPublished = keccak256("ghost");
        bytes memory operatorInput = abi.encodePacked(notPublished);

        vm.expectRevert(BlobNotPublished.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, keccak256(operatorInput), operatorInput, 0);
    }

    function testCheckDANonEmptyBlobVersionHash() public {
        bytes32[] memory blobs = new bytes32[](2);
        blobs[0] = keccak256("b1");
        blobs[1] = keccak256("b2");
        validator.setMockBlobs(blobs);

        // one zero in operator input -> will pull blob0, but blob1 is still non-empty
        bytes memory operatorInput = abi.encodePacked(bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(NonEmptyBlobVersionHash.selector, 1));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, keccak256(operatorInput), operatorInput, 0);
    }

    function testCheckDAInvalidBlobsPublished() public {
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = keccak256("blob");
        validator.setMockBlobs(blobs);

        // ask to pull blob0
        bytes memory operatorInput = abi.encodePacked(bytes32(0));

        bytes32 wrongHash = keccak256("wrong");
        vm.expectRevert(
            abi.encodeWithSelector(InvalidBlobsPublished.selector, keccak256(abi.encodePacked(blobs[0])), wrongHash)
        );
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, wrongHash, operatorInput, 0);
    }

    function testCheckDAVerifiesCorrectly() public {
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = keccak256("blob");
        validator.setMockBlobs(blobs);

        // operator input asks to pull blob0
        bytes memory operatorInput = abi.encodePacked(bytes32(0));
        bytes32 expectedHash = keccak256(abi.encodePacked(blobs[0]));

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory out = validator.checkDA(1, 1, expectedHash, operatorInput, 0);

        assertEq(out.stateDiffHash, bytes32(0));
        assertEq(out.blobsLinearHashes.length, 0);
    }

    function testCheckDAWithMixedProvidedAndPublishedBlob() public {
        // publish one blob beforehand
        bytes32 publishedBlob = keccak256("published");
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = publishedBlob;
        validator.setMockBlobs(blobs);
        validator.publishBlobs();

        // operator provides one directly + one placeholder for pulling from tx (mock)
        bytes32 providedBlob = keccak256("provided");
        bytes32[] memory txBlobs = new bytes32[](1);
        txBlobs[0] = providedBlob;
        validator.setMockBlobs(txBlobs); // will be pulled for the zero placeholder

        bytes memory operatorInput = abi.encodePacked(publishedBlob, bytes32(0));
        bytes32 expectedHash = keccak256(abi.encodePacked(publishedBlob, providedBlob));

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory out = validator.checkDA(1, 1, expectedHash, operatorInput, 0);

        assertEq(out.stateDiffHash, bytes32(0));
        assertEq(out.blobsLinearHashes.length, 0);
    }
}
