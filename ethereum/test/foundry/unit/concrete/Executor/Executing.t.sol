// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./_Executor_Shared.t.sol";

contract ExecutingTest is ExecutorTest {
    function setUp() public {
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;
        newCommitBlockInfo = IExecutor.CommitBlockInfo({
            blockNumber: 1,
            timestamp: uint64(currentTimestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: keccak256(
                bytes.concat("randomBytes32", "setUp()", "0")
            ),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: 0,
            priorityOperationsHash: keccak256(""),
            initialStorageChanges: abi.encodePacked(uint256(0x00000000)),
            repeatedStorageChanges: bytes(""),
            l2Logs: bytes(""),
            l2ArbitraryLengthMessages: new bytes[](0),
            factoryDeps: new bytes[](0)
        });

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );
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

    function test_RevertWhen_ExecutingBlockWithWrongBlockNumber() public {
        IExecutor.StoredBlockInfo
            memory wrongNewStoredBlockInfo = newStoredBlockInfo;
        wrongNewStoredBlockInfo.blockNumber = 10; // Correct is 1

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = wrongNewStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("k"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_RevertWhen_ExecutingBlockWithWrongData() public {
        IExecutor.StoredBlockInfo
            memory wrongNewStoredBlockInfo = newStoredBlockInfo;
        wrongNewStoredBlockInfo.timestamp = 0; // incorrect timestamp

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = wrongNewStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("exe10"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_RevertWhen_ExecutingRevertedBlockWithoutCommittingAndProvingAgain()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("n"));
        executor.executeBlocks(storedBlockInfoArray);
    }

    function test_RevertWhen_ExecutingUnavailablePriorityOperationHash()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_ExecutingUnavailablePriorityOperationHash()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            arbitraryCanonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;
        correctNewCommitBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(
            genesisStoredBlockInfo,
            correctNewCommitBlockInfoArray
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBlockInfo
            memory correctNewStoredBlockInfo = newStoredBlockInfo;
        correctNewStoredBlockInfo.blockHash = entries[0].topics[2];
        correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
        correctNewStoredBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBlockInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBlockInfo[]
            memory correctNewStoredBlockInfoArray = new IExecutor.StoredBlockInfo[](
                1
            );
        correctNewStoredBlockInfoArray[0] = correctNewStoredBlockInfo;

        vm.prank(validator);
        executor.proveBlocks(
            genesisStoredBlockInfo,
            correctNewStoredBlockInfoArray,
            proofInput
        );

        vm.prank(validator);
        vm.expectRevert(bytes.concat("s"));
        executor.executeBlocks(correctNewStoredBlockInfoArray);
    }

    function test_RevertWhen_ExecutingWithUnmatchedPriorityOperationHash()
        public
    {
        vm.prank(validator);
        executor.revertBlocks(0);

        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_ExecutingWithUnmatchedPriorityOperationHash()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            arbitraryCanonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;
        correctNewCommitBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        vm.prank(validator);
        vm.recordLogs();
        executor.commitBlocks(
            genesisStoredBlockInfo,
            correctNewCommitBlockInfoArray
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBlockInfo
            memory correctNewStoredBlockInfo = newStoredBlockInfo;
        correctNewStoredBlockInfo.blockHash = entries[0].topics[2];
        correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
        correctNewStoredBlockInfo
            .priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBlockInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBlockInfo[]
            memory correctNewStoredBlockInfoArray = new IExecutor.StoredBlockInfo[](
                1
            );
        correctNewStoredBlockInfoArray[0] = correctNewStoredBlockInfo;

        vm.prank(validator);
        executor.proveBlocks(
            genesisStoredBlockInfo,
            correctNewStoredBlockInfoArray,
            proofInput
        );

        bytes32 randomFactoryDeps0 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_ExecutingWithUnmatchedPriorityOperationHash()",
                "1"
            )
        );

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps0);

        uint256 gasPrice = 1000000000;
        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        uint256 l2Value = 10 ether;
        uint256 totalCost = baseCost + l2Value;

        mailbox.requestL2Transaction{value: totalCost}(
            address(0),
            l2Value,
            bytes(""),
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps,
            address(0)
        );

        vm.prank(validator);
        vm.expectRevert(bytes.concat("x"));
        executor.executeBlocks(correctNewStoredBlockInfoArray);
    }

    function test_RevertWhen_CommittingBlockWithWrongPreviousBlockHash()
        public
    {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[]
            memory correctNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        correctNewCommitBlockInfoArray[0] = correctNewCommitBlockInfo;

        bytes32 wrongPreviousBlockHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingBlockWithWrongPreviousBlockHash()",
                "0"
            )
        );

        IExecutor.StoredBlockInfo memory genesisBlock = genesisStoredBlockInfo;
        genesisBlock.blockHash = wrongPreviousBlockHash;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("i"));
        executor.commitBlocks(genesisBlock, correctNewCommitBlockInfoArray);
    }

    function test_ShouldExecuteBlockSuccessfully() public {
        IExecutor.StoredBlockInfo[]
            memory storedBlockInfoArray = new IExecutor.StoredBlockInfo[](1);
        storedBlockInfoArray[0] = newStoredBlockInfo;

        vm.prank(validator);
        executor.executeBlocks(storedBlockInfoArray);

        uint256 totalBlocksExecuted = getters.getTotalBlocksExecuted();
        assertEq(totalBlocksExecuted, 1);
    }
}
