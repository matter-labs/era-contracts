// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Utils, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";

import {ExecutorTest, POINT_EVALUATION_PRECOMPILE_RESULT, EMPTY_PREPUBLISHED_COMMITMENT} from "./_Executor_Shared.t.sol";

import {COMMIT_TIMESTAMP_NOT_OLDER, POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {RevertedBatchNotAfterNewLastBatch} from "contracts/common/L1ContractErrors.sol";

contract RevertingTest is ExecutorTest {
    bytes32 l2DAValidatorOutputHash;
    bytes32[] blobVersionedHashes;
    bytes operatorDAInput;

    function setUp() public {
        setUpCommitBatch();

        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        bytes memory l2Logs = Utils.encodePacked(correctL2Logs);
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = l2Logs;
        newCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(uint256(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function setUpCommitBatch() public {
        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

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

        l2DAValidatorOutputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        blobVersionedHashes = new bytes32[](1);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(blobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);
    }

    function test_RevertWhen_RevertingMoreBatchesThanAlreadyCommitted() public {
        vm.prank(validator);
        vm.expectRevert(RevertedBatchNotAfterNewLastBatch.selector);
        executor.revertBatchesSharedBridge(0, 10);
    }

    function test_SuccessfulRevert() public {
        uint256 totalBlocksCommittedBefore = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommittedBefore, 1, "totalBlocksCommittedBefore");

        uint256 totalBlocksVerifiedBefore = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerifiedBefore, 1, "totalBlocksVerifiedBefore");

        vm.prank(validator);
        executor.revertBatchesSharedBridge(0, 0);

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 0, "totalBlocksCommitted");

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 0, "totalBlocksVerified");
    }
}
