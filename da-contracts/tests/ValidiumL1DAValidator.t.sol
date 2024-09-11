// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ValidiumL1DAValidator} from "../contracts/ValidiumL1DAValidator.sol";

contract ValidiumL1DAValidatorTest is Test {

    ValidiumL1DAValidator internal validium;

    function test_checkDARevert() public {
        bytes opertatorDaInput = 12;

        validium.checkDA(1, 1, 1, operatorDAInput, 1);
    }

    function test_checkDA() public {
        bytes1 source = bytes1(0x01);
        bytes defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        validium.checkDA(1, 1, 1, operatorDAInput, 1);
    }
}