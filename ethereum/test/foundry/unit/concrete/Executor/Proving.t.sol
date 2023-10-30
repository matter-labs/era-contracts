// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Test.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER} from "../../../../../cache/solpp-generated-contracts/zksync/Config.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";

contract ProvingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes[] memory correctL2Logs = Utils.createSystemLogs();
        correctL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils
            .constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
            );

        bytes memory l2Logs = Utils.encodePacked(correctL2Logs);

        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.systemLogs = l2Logs;

        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBatches(genesisStoredBatchInfo, commitBatchInfoArray);
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
    }

    function test_RevertWhen_ProvingWithWrongPreviousBlockData() public {
        IExecutor.StoredBatchInfo memory wrongPreviousStoredBatchInfo = genesisStoredBatchInfo;
        wrongPreviousStoredBatchInfo.batchNumber = 10; // Correct is 0

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t1"));
        executor.proveBatches(wrongPreviousStoredBatchInfo, storedBatchInfoArray, proofInput);
    }

    function test_RevertWhen_ProvingWithWrongCommittedBlock() public {
        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = wrongNewStoredBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("o1"));
        executor.proveBatches(genesisStoredBatchInfo, storedBatchInfoArray, proofInput);
    }

    function test_RevertWhen_ProvingRevertedBlockWithoutCommittingAgain() public {
        vm.prank(validator);
        executor.revertBatches(0);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("q"));
        executor.proveBatches(genesisStoredBatchInfo, storedBatchInfoArray, proofInput);
    }

    function test_SuccessfulProve() public {
        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);

        executor.proveBatches(genesisStoredBatchInfo, storedBatchInfoArray, proofInput);

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 1);
    }
}
