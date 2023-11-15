// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Test.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";

contract CommittingTest is ExecutorTest {
    function test_RevertWhen_ComittingWithWrongLastCommittedBatchData() public {
        IExecutor.CommitBatchInfo[] memory newCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        newCommitBatchInfoArray[0] = newCommitBatchInfo;

        IExecutor.StoredBatchInfo memory wrongGenesisStoredBatchInfo = genesisStoredBatchInfo;
        wrongGenesisStoredBatchInfo.timestamp = 1000;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("i"));
        executor.commitBatches(wrongGenesisStoredBatchInfo, newCommitBatchInfoArray);
    }

    function test_RevertWhen_ComittingWithWrongOrderOfBatches() public {
        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.batchNumber = 2; // wrong batch number

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("f"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNewBatchTimestamp() public {
        bytes32 wrongNewBatchTimestamp = Utils.randomBytes32("wrongNewBatchTimestamp");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();

        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils
            .constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                wrongNewBatchTimestamp
            );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("tb"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithTooSmallNewBatchTimestamp() public {
        uint256 wrongNewBatchTimestamp = 1;
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils
            .constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                Utils.packBatchTimestampAndBlockTimestamp(1, 1)
            );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.timestamp = uint64(wrongNewBatchTimestamp);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h1"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingTooBigLastL2BatchTimestamp() public {
        uint64 wrongNewBatchTimestamp = 0xffffffff;
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils
            .constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                Utils.packBatchTimestampAndBlockTimestamp(wrongNewBatchTimestamp, wrongNewBatchTimestamp)
            );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.timestamp = wrongNewBatchTimestamp;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h2"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongPreviousBatchHash() public {
        bytes32 wrongPreviousBatchHash = Utils.randomBytes32("wrongPreviousBatchHash");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(Utils.SystemLogKeys.PREV_BATCH_HASH_KEY),
            wrongPreviousBatchHash
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("l"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithoutProcessingSystemContextLog() public {
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        delete wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))];

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("b7"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithProcessingSystemContextLogTwice() public {
        bytes[] memory l2Logs = Utils.createSystemLogs();

        bytes memory wrongL2Logs = abi.encodePacked(
            Utils.encodePacked(l2Logs),
            Utils.constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                bytes32("")
            )
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = wrongL2Logs;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("kp"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_UnexpectedL2ToL1Log() public {
        address unexpectedAddress = address(0);
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils
            .constructL2Log(
                true,
                unexpectedAddress,
                uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                bytes32("")
            );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("sc"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongCanonicalTxHash() public {
        bytes32 wrongChainedPriorityHash = Utils.randomBytes32("canonicalTxHash");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.CHAINED_PRIORITY_TXN_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(Utils.SystemLogKeys.CHAINED_PRIORITY_TXN_HASH_KEY),
            wrongChainedPriorityHash
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNumberOfLayer1txs() public {
        bytes[] memory wrongL2Logs = Utils.createSystemLogs();
        wrongL2Logs[uint256(uint256(Utils.SystemLogKeys.NUMBER_OF_LAYER_1_TXS_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(Utils.SystemLogKeys.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(bytes1(0x01))
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.numberOfLayer1Txs = 2;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ta"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_CommittingWithUnknownSystemLogKey() public {
        bytes[] memory l2Logs = Utils.createSystemLogs();
        bytes memory wrongL2Logs = abi.encodePacked(
            Utils.encodePacked(l2Logs),
            abi.encodePacked(bytes2(0x0001), bytes2(0x0000), L2_SYSTEM_CONTEXT_ADDRESS, uint256(119), bytes32(""))
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = abi.encodePacked(bytes4(0x00000008), wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ul"));
        executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
    }

    function test_RevertWhen_SystemLogIsFromIncorrectAddress() public {
        bytes32[7] memory values = [
            bytes32(""),
            bytes32(0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563),
            bytes32(""),
            bytes32(""),
            bytes32(""),
            keccak256(""),
            bytes32("")
        ];

        bytes[7] memory errors = [
            bytes.concat("lm"),
            bytes.concat("ln"),
            bytes.concat("lb"),
            bytes.concat("sc"),
            bytes.concat("sv"),
            bytes.concat("bl"),
            bytes.concat("bk")
        ];

        for (uint256 i = 0; i < values.length; i++) {
            bytes[] memory wrongL2Logs = Utils.createSystemLogs();
            address wrongAddress = makeAddr("randomAddress");
            wrongL2Logs[i] = Utils.constructL2Log(true, wrongAddress, i, values[i]);

            IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
            wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

            IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
            wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

            vm.prank(validator);

            vm.expectRevert(errors[i]);
            executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
        }
    }

    function test_RevertWhen_SystemLogIsMissing() public {
        for (uint256 i = 0; i < 7; i++) {
            bytes[] memory l2Logs = Utils.createSystemLogs();
            delete l2Logs[i];

            IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
            wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(l2Logs);

            IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
            wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

            vm.prank(validator);

            vm.expectRevert(bytes.concat("b7"));
            executor.commitBatches(genesisStoredBatchInfo, wrongNewCommitBatchInfoArray);
        }
    }

    function test_SuccessfullyCommitBatch() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs();
        correctL2Logs[uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(Utils.SystemLogKeys.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);

        vm.recordLogs();

        executor.commitBatches(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // batchNumber

        uint256 totalBatchesCommitted = getters.getTotalBatchesCommitted();
        assertEq(totalBatchesCommitted, 1);
    }
}
