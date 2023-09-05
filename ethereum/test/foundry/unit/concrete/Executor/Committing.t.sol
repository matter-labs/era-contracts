// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./_Executor_Shared.t.sol";

contract CommittingTest is ExecutorTest {
    function setUp() public {
        // foundry's default value is 1 for the block's timestamp, it is expected
        // that block.timestamp > COMMIT_TIMESTAMP_NOT_OLDER
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
    }

    function test_RevertWhen_ComittingWithWrongLastCommittedBlockData() public {
        IExecutor.CommitBlockInfo[]
            memory newCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](1);
        newCommitBlockInfoArray[0] = newCommitBlockInfo;

        IExecutor.StoredBlockInfo
            memory wrongGenesisStoredBlockInfo = genesisStoredBlockInfo;
        wrongGenesisStoredBlockInfo.timestamp = 1000;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("i"));
        executor.commitBlocks(
            wrongGenesisStoredBlockInfo,
            newCommitBlockInfoArray
        );
    }

    function test_RevertWhen_ComittingWithWrongOrderOfBlocks() public {
        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.blockNumber = 2; // wrong block number

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("f"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongNewBlockTimestamp() public {
        bytes32 wrongNewBlockTimestamp = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingWithWrongNewBlockTimestamp()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            wrongNewBlockTimestamp,
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("tb"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithTooSmallNewBlockTimestamp() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            bytes32(0),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = 0;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingTooBigNewBlockTimestamp() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            address(L2_SYSTEM_CONTEXT_ADDRESS),
            uint256(0xffffffff),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.timestamp = 0xffffffff;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("h1"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongPreviousBlockHash() public {
        bytes32 wrongPreviousBlockHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_committingWithWrongPreviousBlockHash()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            wrongPreviousBlockHash
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("l"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithoutProcessingSystemContextLog()
        public
    {
        bytes memory wrongL2Logs = abi.encodePacked(bytes4(0x00000000));

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("by"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithProcessingSystemContextLogTwice()
        public
    {
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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("fx"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_UnexpectedL1ToL2Log() public {
        address unexpectedAddress = address(0);
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            unexpectedAddress,
            uint256(currentTimestamp)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ne"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongCanonicalTxHash() public {
        bytes32 randomBytes32 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_committingWithWrongCanonicalTxHash()",
                "0"
            )
        );
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_BOOTLOADER_ADDRESS,
            randomBytes32,
            uint256(1)
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("t"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongNumberOfLayer1txs() public {
        bytes32 arbitraryCanonicalTxHash = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingWithWrongNumberOfLayer1txs()",
                "0"
            )
        );
        bytes32 chainedPriorityTxHash = keccak256(
            bytes.concat(keccak256(""), arbitraryCanonicalTxHash)
        );

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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.priorityOperationsHash = bytes32(
            chainedPriorityTxHash
        );
        wrongNewCommitBlockInfo.numberOfLayer1Txs = 2;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ta"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongFactoryDepsData() public {
        bytes32 randomFactoryDeps0 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingWithWrongFactoryDepsData()",
                "0"
            )
        );
        bytes32 randomFactoryDeps1 = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingWithWrongFactoryDepsData()",
                "1"
            )
        );

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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k3"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongFactoryDepsArrayLength()
        public
    {
        bytes32 arbitraryBytecode = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_CommittingWithWrongFactoryDepsArrayLength()",
                "0"
            )
        );
        bytes32 arbitraryBytecodeHash = sha256(bytes.concat(arbitraryBytecode));
        uint256 arbitraryBytecodeHashManipulated1 = uint256(
            arbitraryBytecodeHash
        ) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = bytes.concat(arbitraryBytecode);
        factoryDeps[1] = bytes.concat(arbitraryBytecode);

        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("ym"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_ComittingWithWrongHashedMessage() public {
        bytes32 randomL2LogValue = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_ComittingWithWrongHashedMessage()",
                "0"
            )
        );

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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

        bytes32 randomL2Message = keccak256(
            bytes.concat(
                "randomBytes32",
                "test_RevertWhen_ComittingWithWrongHashedMessage()",
                "1"
            )
        );

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](1);
        l2ArbitraryLengthMessages[0] = bytes.concat(randomL2Message);

        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("k2"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
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

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;

        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessagesArray;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);
        vm.expectRevert(bytes.concat("pl"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongBytecodeLength() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_RevertWhen_CommittingWithWrongBytecodeLength()",
                    "0"
                )
            )
        );

        bytes20 randomFactoryDeps1 = bytes20(
            keccak256(
                bytes.concat(
                    "randomBytes20",
                    "test_RevertWhen_CommittingWithWrongBytecodeLength()",
                    "0"
                )
            )
        );
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("bl"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongNumberOfWordsInBytecode()
        public
    {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000002),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            bytes4(0x00010000),
            L2_KNOWN_CODE_STORAGE_ADDRESS,
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_RevertWhen_CommittingWithWrongNumberOfWordsInBytecode()",
                    "0"
                )
            )
        );

        bytes memory randomFactoryDeps1 = bytes.concat(
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_RevertWhen_CommittingWithWrongNumberOfWordsInBytecode()",
                    "0"
                )
            ),
            keccak256(
                bytes.concat(
                    "randomBytes32",
                    "test_RevertWhen_CommittingWithWrongNumberOfWordsInBytecode()",
                    "1"
                )
            )
        );

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps1);

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.factoryDeps = factoryDeps;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pr"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithWrongRepeatedStorageWrites() public {
        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo.indexRepeatedStorageChanges = 0;
        wrongNewCommitBlockInfo.initialStorageChanges = "0x00000001";

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("yq"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_RevertWhen_CommittingWithTooLongL2Logs() public {
        // uint256 constant MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES = 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * 512;
        bytes memory arr1;

        for (uint i = 0; i < 512; i++) {
            arr1 = abi.encodePacked(
                arr1,
                bytes4(0x00000000),
                L2_TO_L1_MESSENGER,
                bytes32(""),
                keccak256("")
            );
        }

        bytes memory wrongL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(currentTimestamp),
            bytes32(""),
            arr1
        );

        bytes[] memory l2ArbitraryLengthMessages = new bytes[](512);

        for (uint i = 0; i < l2ArbitraryLengthMessages.length; i++) {
            l2ArbitraryLengthMessages[i] = bytes("");
        }

        IExecutor.CommitBlockInfo
            memory wrongNewCommitBlockInfo = newCommitBlockInfo;
        wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
        wrongNewCommitBlockInfo
            .l2ArbitraryLengthMessages = l2ArbitraryLengthMessages;

        IExecutor.CommitBlockInfo[]
            memory wrongNewCommitBlockInfoArray = new IExecutor.CommitBlockInfo[](
                1
            );
        wrongNewCommitBlockInfoArray[0] = wrongNewCommitBlockInfo;

        vm.prank(validator);

        vm.expectRevert(bytes.concat("pu"));
        executor.commitBlocks(
            genesisStoredBlockInfo,
            wrongNewCommitBlockInfoArray
        );
    }

    function test_ShouldCommitBlock() public {
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

        assertEq(entries.length, 1);
        assertEq(
            entries[0].topics[0],
            keccak256("BlockCommit(uint256,bytes32,bytes32)")
        );
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // blockNumber
        assertEq(
            entries[0].topics[2],
            bytes32(
                0x5391aedfa307cfbb5523d0ba566759d1b5c0901dcb5868a195addafd5e9dd563
            )
        ); // blockHash
        assertEq(
            entries[0].topics[3],
            bytes32(
                0x00cc2f6937a02033a72880ac0f2a2a7caeb8795676538437e1277d2b6e6c6fb5
            )
        ); // commitment

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 1);
    }
}
