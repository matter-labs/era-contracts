// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vm} from "forge-std/Test.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {L2_BOOTLOADER_ADDRESS} from "../../../../../cache/solpp-generated-contracts/common/L2ContractAddresses.sol";
import {IExecutor} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IExecutor.sol";

contract CommittingTest is ExecutorTest {
    function test_RevertWhen_ComittingWithWrongLastCommittedBlockData() public {
        IExecutor.CommitBlockInfo[] memory newCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        newCommitBlockInfoArray[0] = newCommitBlockInfo;

        IExecutor.StoredBlockInfo memory wrongGenesisStoredBlockInfo = genesisStoredBlockInfo;
        wrongGenesisStoredBlockInfo.timestamp = 1000;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("i"));
        executor.commitBlocks(wrongGenesisStoredBlockInfo, newCommitBlockInfoArray);
    }

    function test_RevertWhen_ComittingWithWrongOrderOfBlocks() public {
        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.blockNumber = 2; // wrong block number

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("f"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNewBlockTimestamp() public {
        bytes32 wrongNewBlockTimestamp = Utils.randomBytes32("wrongNewBlockTimestamp");
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            wrongNewBlockTimestamp,
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("tb"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithTooSmallNewBlockTimestamp() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            Utils.packBatchTimestampAndBlockTimestamp(1, 1),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = 1; // too small

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h1"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingTooBigLastL2BlockTimestamp() public {
        uint64 wrongL2BlockTimestamp = 0xffffffff;
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            Utils.packBatchTimestampAndBlockTimestamp(wrongL2BlockTimestamp, wrongL2BlockTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = wrongL2BlockTimestamp;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h2"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongPreviousBlockHash() public {
        bytes32 wrongPreviousBlockHash = Utils.randomBytes32("wrongPreviousBlockHash");
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            wrongPreviousBlockHash
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("l"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithoutProcessingSystemContextLog() public {
        bytes memory wrongL2Logs = abi.encodePacked(bytes4(0x00000000));

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("by"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithProcessingSystemContextLogTwice() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("fx"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_UnexpectedL2ToL1Log() public {
        address unexpectedAddress = address(0);
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            unexpectedAddress,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ne"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongCanonicalTxHash() public {
        bytes32 canonicalTxHash = Utils.randomBytes32("canonicalTxHash");

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            canonicalTxHash,
            uint256(1)
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNumberOfLayer1txs() public {
        bytes32 arbitraryCanonicalTxHash = Utils.randomBytes32("arbitraryCanonicalTxHash");
        bytes32 chainedPriorityTxHash = keccak256(bytes.concat(keccak256(""), arbitraryCanonicalTxHash));

        bytes memory wrongL2Logs = abi.encodePacked(
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

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.priorityOperationsHash = bytes32(chainedPriorityTxHash);
        wrongNewCommitBlockInfo.numberOfLayer1Txs = 2;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ta"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongFactoryDepsData() public {
        bytes32 randomFactoryDeps0 = Utils.randomBytes32("randomFactoryDeps0");
        bytes32 randomFactoryDeps1 = Utils.randomBytes32("randomFactoryDeps1");

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            randomFactoryDeps0
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k3"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongFactoryDepsArrayLength() public {
        bytes32 arbitraryBytecode = Utils.randomBytes32("arbitraryBytecode");
        bytes32 arbitraryBytecodeHash = sha256(bytes.concat(arbitraryBytecode));
        uint256 arbitraryBytecodeHashManipulated1 = uint256(arbitraryBytecodeHash) &
            0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        uint256 arbitraryBytecodeHashManipulated2 = arbitraryBytecodeHashManipulated1 |
            0x0100000100000000000000000000000000000000000000000000000000000000;

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            uint256(arbitraryBytecodeHashManipulated2)
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = bytes.concat(arbitraryBytecode);
        factoryDeps[1] = bytes.concat(arbitraryBytecode);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ym"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_ComittingWithWrongHashedMessage() public {
        bytes32 randomL2LogValue = Utils.randomBytes32("randomL2LogValue");

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_TO_L1_MESSENGER,
            bytes32(""),
            randomL2LogValue
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes32 randomL2Message = Utils.randomBytes32("randomL2Message");

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](1);
        l2ArbitraryLengthMessages[0] = bytes.concat(randomL2Message);

        wrongNewCommitBlockInfo.l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k2"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNumberOfMessages() public {
        bytes memory arbitraryMessage = abi.encodePacked(uint8(0xaa));
        bytes32 arbitraryHashedMessage = keccak256(arbitraryMessage);

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_TO_L1_MESSENGER,
            bytes32(""),
            arbitraryHashedMessage
        );

        bytes[] memory l2ArbitraryLengthMessagesArray = new bytes[](2);
        l2ArbitraryLengthMessagesArray[0] = arbitraryMessage;
        l2ArbitraryLengthMessagesArray[1] = arbitraryMessage;

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;

        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.l2ArbitraryLengthMessages = l2ArbitraryLengthMessagesArray;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("pl"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongBytecodeLength() public {
        bytes32 randomFactoryDeps0 = Utils.randomBytes32("randomFactoryDeps0");

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            randomFactoryDeps0
        );

        bytes20 randomFactoryDeps1 = bytes20(randomFactoryDeps0);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("bl"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongNumberOfWordsInBytecode() public {
        bytes32 randomFactoryDeps0 = Utils.randomBytes32("randomFactoryDeps0");

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            randomFactoryDeps0
        );

        bytes memory randomFactoryDeps1 = bytes.concat(randomFactoryDeps0, randomFactoryDeps0);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pr"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithWrongRepeatedStorageWrites() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.indexRepeatedStorageChanges = 0;
        wrongNewCommitBlockInfo.initialStorageChanges = "0x00000001";

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("yq"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingWithTooLongL2Logs() public {
        // uint256 constant MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES = 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * 512;
        bytes memory arr1;

        for (uint16 i = 0; i < 512; i++) {
            arr1 = abi.encodePacked(arr1, bytes4(0x00000000), L2_TO_L1_MESSENGER, bytes32(""), keccak256(""));
        }

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32(""),
            arr1
        );

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](512);

        for (uint16 i = 0; i < l2ArbitraryLengthMessages.length; i++) {
            l2ArbitraryLengthMessages[i] = bytes("");
        }

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pu"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingTooLongRepeatedStorageChanges() public {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        // 7565 * 40 bytes = 302600 bytes long repeatedStorageChanges
        // which is longer than 302564 (MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES =
        // 4 + REPEATED_STORAGE_CHANGE_SERIALIZE_SIZE * 7564)
        uint256 wrongRepeatedStorageChangesLen = 7565 * 40;
        bytes memory wrongRepeatedStorageChanges = new bytes(wrongRepeatedStorageChangesLen);

        assembly {
            let ptr := add(wrongRepeatedStorageChanges, 32)
            let end := add(ptr, wrongRepeatedStorageChangesLen)

            for {

            } lt(ptr, end) {

            } {
                mstore(ptr, 0x0000000000000000000000000000000000000000000000000000000000000000)
                ptr := add(ptr, 40)
            }
        }

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = correctL2Logs;
        wrongNewCommitBlockInfo.repeatedStorageChanges = wrongRepeatedStorageChanges;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("py"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_RevertWhen_CommittingTooLongInitialStorageChanges() public {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        // 4766 * 64 bytes = 305024 bytes long initialStorageChangesLen
        // which is longer than 304964 (MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES =
        // 4 + INITIAL_STORAGE_CHANGE_SERIALIZE_SIZE * 4765)
        uint256 wrongInitialStorageChangesLen = 4766 * 64;
        bytes memory wrongInitialStorageChanges = new bytes(wrongInitialStorageChangesLen);

        assembly {
            let ptr := add(wrongInitialStorageChanges, 32)
            let end := add(ptr, wrongInitialStorageChangesLen)

            for {

            } lt(ptr, end) {

            } {
                mstore(ptr, 0x0000000000000000000000000000000000000000000000000000000000000000)
                ptr := add(ptr, 64)
            }
        }

        IExecutor.CommitBlockInfo memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = correctL2Logs;
        wrongNewCommitBlockInfo.initialStorageChanges = wrongInitialStorageChanges;

        IExecutor.CommitBlockInfo[] memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pf"));
        executor.commitBlocks(genesisStoredBlockInfo, wrongNewCommitBlockInfoArray);
    }

    function test_SuccessfullyCommitBlock() public {
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo memory correctNewCommitBlockInfo = newCommitBlockInfo;
        correctNewCommitBlockInfo.l2Logs = correctL2Logs;

        IExecutor.CommitBlockInfo[] memory commitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        commitBlockInfoArray[0] = correctNewCommitBlockInfo;

        vm.prank(validator);

        vm.recordLogs();

        executor.commitBlocks(genesisStoredBlockInfo, commitBlockInfoArray);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // blockNumber

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 1);
    }
}
