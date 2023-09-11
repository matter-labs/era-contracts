// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./_Executor_Shared.t.sol";

contract RevertingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(
                currentTimestamp,
                currentTimestamp
            ),
            bytes32("")
        );

        newCommitBlockInfo.timestamp = uint64(currentTimestamp);
        newCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = newCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBlockInfo = IExecutor.StoredBlockInfo({
            blockNumber: 1,
            blockHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);

        executor.proveBlocks(
            genesisStoredBlockInfo,
            storedBlockInfoArray,
            proofInput
        );
    }

    function test_RevertWhen_RevertingMoreBlocksThanAlreadyCommitted() public {
        vm.prank(validator);
        vm.expectRevert(bytes.concat("v1"));
        executor.revertBlocks(10);
    }

    function test_SuccessfulRevert() public {
        uint256 totalBlocksCommittedBefore = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommittedBefore, 1, "totalBlocksCommittedBefore");

        uint256 totalBlocksVerifiedBefore = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerifiedBefore, 1, "totalBlocksVerifiedBefore");

        vm.prank(validator);
        executor.revertBlocks(0);

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 0, "totalBlocksCommitted");

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 0, "totalBlocksVerified");
    }
}
