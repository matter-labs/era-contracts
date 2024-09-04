// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {TestStateDiffComposer} from "./TestStateDiffComposer.sol";

import {RollupL2DAValidator} from "contracts/data-availability/RollupL2DAValidator.sol";
import {STATE_DIFF_ENTRY_SIZE} from "contracts/data-availability/StateDiffL2DAValidator.sol";
import {ReconstructionMismatch, PubdataField} from "contracts/data-availability/DAErrors.sol";

import {COMPRESSOR_CONTRACT, PUBDATA_CHUNK_PUBLISHER} from "contracts/L2ContractHelper.sol";

import {console2 as console} from "forge-std/Script.sol";

contract RollupL2DAValidatorTest is Test {
    RollupL2DAValidator internal l2DAValidator;
    TestStateDiffComposer internal composer;

    function setUp() public {
        l2DAValidator = new RollupL2DAValidator();
        composer = new TestStateDiffComposer();

        bytes memory emptyArray = new bytes(0);

        // Setting dummy state diffs, so it works fine.
        composer.setDummyStateDiffs(1, 0, 64, emptyArray, 0, emptyArray);

        bytes memory verifyCompressedStateDiffsData = abi.encodeCall(
            COMPRESSOR_CONTRACT.verifyCompressedStateDiffs,
            (0, 64, emptyArray, emptyArray)
        );
        vm.mockCall(address(COMPRESSOR_CONTRACT), verifyCompressedStateDiffsData, new bytes(32));

        bytes memory chunkPubdataToBlobsData = abi.encodeCall(
            PUBDATA_CHUNK_PUBLISHER.chunkPubdataToBlobs,
            (emptyArray)
        );
        vm.mockCall(address(PUBDATA_CHUNK_PUBLISHER), chunkPubdataToBlobsData, new bytes(32));
    }

    function finalizeAndCall(bytes memory revertMessage) internal returns (bytes32) {
        bytes32 rollingMessagesHash = composer.correctRollingMessagesHash();
        bytes32 rollingBytecodeHash = composer.correctRollingBytecodesHash();
        bytes memory totalL2ToL1PubdataAndStateDiffs = composer.generateTotalStateDiffsAndPubdata();

        if (revertMessage.length > 0) {
            vm.expectRevert(revertMessage);
        }
        return
            l2DAValidator.validatePubdata(
                bytes32(0),
                bytes32(0),
                rollingMessagesHash,
                rollingBytecodeHash,
                totalL2ToL1PubdataAndStateDiffs
            );
    }

    function test_incorrectChainMessagesHash() public {
        composer.appendAMessage("message", true, false);

        bytes memory revertMessage = abi.encodeWithSelector(
            ReconstructionMismatch.selector,
            PubdataField.MsgHash,
            composer.correctRollingMessagesHash(),
            composer.currentRollingMessagesHash()
        );
        finalizeAndCall(revertMessage);
    }

    function test_incorrectChainBytecodeHash() public {
        composer.appendBytecode(new bytes(32), true, false);

        bytes memory revertMessage = abi.encodeWithSelector(
            ReconstructionMismatch.selector,
            PubdataField.Bytecode,
            composer.correctRollingBytecodesHash(),
            composer.currentRollingBytecodesHash()
        );
        finalizeAndCall(revertMessage);
    }

    function test_incorrectStateDiffVersion() public {
        composer.setDummyStateDiffs(2, 0, 64, new bytes(0), 0, new bytes(0));

        bytes memory revertMessage = abi.encodeWithSelector(
            ReconstructionMismatch.selector,
            PubdataField.StateDiffCompressionVersion,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
        finalizeAndCall(revertMessage);
    }

    function test_nonZeroLeftOver() public {
        composer.setDummyStateDiffs(1, 0, 64, new bytes(0), 0, new bytes(32));

        bytes memory revertMessage = abi.encodeWithSelector(
            ReconstructionMismatch.selector,
            PubdataField.ExtraData,
            bytes32(0),
            bytes32(uint256(32))
        );
        finalizeAndCall(revertMessage);
    }

    function test_fullCorrectCompression() public {
        composer.appendAMessage("message", true, true);
        composer.appendBytecode(new bytes(32), true, true);

        uint256 numberOfStateDiffs = 1;
        // Just some non-zero array, the structure does not matter here.
        bytes memory compressedStateDiffs = new bytes(12);
        bytes memory uncompressedStateDiffs = new bytes(STATE_DIFF_ENTRY_SIZE * numberOfStateDiffs);

        composer.setDummyStateDiffs(
            1,
            uint24(compressedStateDiffs.length),
            64,
            compressedStateDiffs,
            uint32(numberOfStateDiffs),
            uncompressedStateDiffs
        );

        bytes32 stateDiffsHash = keccak256(uncompressedStateDiffs);
        bytes memory verifyCompressedStateDiffsData = abi.encodeCall(
            COMPRESSOR_CONTRACT.verifyCompressedStateDiffs,
            (numberOfStateDiffs, 64, uncompressedStateDiffs, compressedStateDiffs)
        );
        vm.mockCall(address(COMPRESSOR_CONTRACT), verifyCompressedStateDiffsData, abi.encodePacked(stateDiffsHash));

        bytes memory totalPubdata = composer.getTotalPubdata();
        bytes32 blobHash = keccak256(totalPubdata);
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = blobHash;
        bytes memory chunkPubdataToBlobsData = abi.encodeCall(
            PUBDATA_CHUNK_PUBLISHER.chunkPubdataToBlobs,
            (totalPubdata)
        );
        vm.mockCall(address(PUBDATA_CHUNK_PUBLISHER), chunkPubdataToBlobsData, abi.encode(blobHashes));

        bytes32 operatorDAHash = finalizeAndCall(new bytes(0));

        bytes32 expectedOperatorDAHash = keccak256(
            abi.encodePacked(stateDiffsHash, keccak256(totalPubdata), uint8(blobHashes.length), blobHashes)
        );

        assertEq(operatorDAHash, expectedOperatorDAHash);
    }
}
