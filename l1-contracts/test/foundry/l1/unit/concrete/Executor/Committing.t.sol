// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS, L2_TO_L1_MESSENGER} from "../Utils/Utils.sol";
import {ExecutorTest, EMPTY_PREPUBLISHED_COMMITMENT, POINT_EVALUATION_PRECOMPILE_RESULT} from "./_Executor_Shared.t.sol";

import {IExecutor, SystemLogKey, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {L2_PUBDATA_CHUNK_PUBLISHER_ADDR, L2_MESSAGE_ROOT_STORAGE} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {BLS_MODULUS} from "../../../da-contracts-imports/DAUtils.sol";
import {BLOB_DATA_OFFSET} from "../../../da-contracts-imports/CalldataDA.sol";
import {PubdataCommitmentsEmpty, BlobHashCommitmentError, OperatorDAInputTooSmall, EmptyBlobVersionHash, InvalidPubdataCommitmentsSize, NonEmptyBlobVersionHash} from "../../../da-contracts-imports/DAContractsErrors.sol";
import {TimeNotReached, BatchNumberMismatch, L2TimestampTooBig, CanOnlyProcessOneBatch, TimestampError, LogAlreadyProcessed, InvalidLogSender, UnexpectedSystemLog, HashMismatch, BatchHashMismatch, ValueMismatch, MissingSystemLogs} from "contracts/common/L1ContractErrors.sol";

contract CommittingTest is ExecutorTest {
    bytes32[] defaultBlobVersionedHashes;
    bytes32 l2DAValidatorOutputHash;
    bytes operatorDAInput;
    bytes defaultBlobCommitment;
    bytes16 defaultBlobOpeningPoint = 0x7142c5851421a2dc03dde0aabdb0ffdb;
    bytes32 defaultBlobClaimedValue = 0x1e5eea3bbb85517461c1d1c7b84c7c2cec050662a5e81a71d5d7e2766eaff2f0;

    function setUp() public {
        // the values below are taken from the actual blob used by Era
        bytes1 source = bytes1(0x01);
        defaultBlobCommitment = Utils.getDefaultBlobCommitment();

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

        defaultBlobVersionedHashes = new bytes32[](1);
        defaultBlobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(defaultBlobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);
    }

    function test_RevertWhen_CommittingWithWrongLastCommittedBatchData() public {
        IExecutor.CommitBatchInfo[] memory newCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        newCommitBatchInfoArray[0] = newCommitBatchInfo;

        IExecutor.StoredBatchInfo memory wrongGenesisStoredBatchInfo = genesisStoredBatchInfo;
        wrongGenesisStoredBatchInfo.timestamp = 1000;

        vm.prank(validator);

        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(genesisStoredBatchInfo)),
                keccak256(abi.encode(wrongGenesisStoredBatchInfo))
            )
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            wrongGenesisStoredBatchInfo,
            newCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongOrderOfBatches() public {
        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.batchNumber = 2; // wrong batch number

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(BatchNumberMismatch.selector, uint256(1), uint256(2)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongNewBatchTimestamp() public {
        bytes32 wrongNewBatchTimestamp = Utils.randomBytes32("wrongNewBatchTimestamp");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);

        wrongL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            wrongNewBatchTimestamp
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(TimestampError.selector);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithTooSmallNewBatchTimestamp() public {
        uint256 wrongNewBatchTimestamp = 1;
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(1, 1)
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.timestamp = uint64(wrongNewBatchTimestamp);
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, 1, 2));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingTooBigLastL2BatchTimestamp() public {
        uint64 wrongNewBatchTimestamp = 0xffffffff;
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(wrongNewBatchTimestamp, wrongNewBatchTimestamp)
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.timestamp = wrongNewBatchTimestamp;
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(L2TimestampTooBig.selector));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongPreviousBatchHash() public {
        bytes32 wrongPreviousBatchHash = Utils.randomBytes32("wrongPreviousBatchHash");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.PREV_BATCH_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PREV_BATCH_HASH_KEY),
            wrongPreviousBatchHash
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(HashMismatch.selector, wrongPreviousBatchHash, bytes32(0)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithoutProcessingSystemContextLog() public {
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        delete wrongL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))];

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(MissingSystemLogs.selector, 255, 253));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithProcessingSystemContextLogTwice() public {
        bytes[] memory l2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);

        bytes memory wrongL2Logs = abi.encodePacked(
            Utils.encodePacked(l2Logs),
            // solhint-disable-next-line func-named-parameters
            Utils.constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
                bytes32("")
            )
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = wrongL2Logs;
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(LogAlreadyProcessed.selector, 1));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_UnexpectedL2ToL1Log() public {
        address unexpectedAddress = address(0);
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            unexpectedAddress,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            bytes32("")
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLogSender.selector,
                address(0),
                uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)
            )
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongCanonicalTxHash() public {
        bytes32 wrongChainedPriorityHash = Utils.randomBytes32("canonicalTxHash");
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            wrongChainedPriorityHash
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.blobhashes(defaultBlobVersionedHashes);
        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(HashMismatch.selector, wrongChainedPriorityHash, keccak256("")));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongNumberOfLayer1txs() public {
        bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        wrongL2Logs[uint256(uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(bytes1(0x01))
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);
        wrongNewCommitBatchInfo.numberOfLayer1Txs = 2;
        wrongNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.blobhashes(defaultBlobVersionedHashes);
        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, uint256(bytes32(bytes1(0x01))), uint256(2)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithUnknownSystemLogKey() public {
        bytes[] memory l2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        bytes memory wrongL2Logs = abi.encodePacked(
            Utils.encodePacked(l2Logs),
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(bytes2(0x0001), bytes2(0x0000), L2_SYSTEM_CONTEXT_ADDRESS, uint256(1234), bytes32(""))
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = abi.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedSystemLog.selector, uint256(1234)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            wrongNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_SystemLogIsFromIncorrectAddress() public {
        bytes32[7] memory values = [
            bytes32(""),
            bytes32(""),
            bytes32(""),
            bytes32(""),
            bytes32(""),
            bytes32(""),
            bytes32("")
        ];

        for (uint256 i = 0; i < values.length; i++) {
            bytes[] memory wrongL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
            address wrongAddress = makeAddr("randomAddress");
            wrongL2Logs[i] = Utils.constructL2Log(true, wrongAddress, i, values[i]);

            IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
            wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(wrongL2Logs);

            IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
            wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

            vm.prank(validator);

            vm.expectRevert(abi.encodeWithSelector(InvalidLogSender.selector, wrongAddress, i));
            (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
                genesisStoredBatchInfo,
                wrongNewCommitBatchInfoArray
            );
            executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        }
    }

    function test_RevertWhen_SystemLogIsMissing() public {
        for (uint256 i = 0; i < 7; i++) {
            bytes[] memory l2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
            delete l2Logs[i];

            IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
            wrongNewCommitBatchInfo.systemLogs = Utils.encodePacked(l2Logs);

            IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
            wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

            vm.prank(validator);

            uint256 allLogsProcessed = uint256(255);
            vm.expectRevert(
                abi.encodeWithSelector(MissingSystemLogs.selector, allLogsProcessed, allLogsProcessed ^ (1 << i))
            );
            (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
                genesisStoredBatchInfo,
                wrongNewCommitBatchInfoArray
            );
            executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        }
    }

    function test_SuccessfullyCommitBatch() public {
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
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        l2DAValidatorOutputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        bytes32[] memory blobHashes = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobHashes[0] = blobsLinearHashes[0];

        bytes32[] memory blobCommitments = new bytes32[](TOTAL_BLOBS_IN_COMMITMENT);
        blobCommitments[0] = keccak256(
            abi.encodePacked(
                defaultBlobVersionedHashes[0],
                abi.encodePacked(defaultBlobOpeningPoint, defaultBlobClaimedValue)
            )
        );

        bytes32 expectedBatchCommitment = Utils.createBatchCommitment(
            correctNewCommitBatchInfo,
            uncompressedStateDiffHash,
            blobCommitments,
            blobHashes
        );

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // batchNumber
        assertEq(entries[0].topics[2], correctNewCommitBatchInfo.newStateRoot); // batchHash
        assertEq(entries[0].topics[3], expectedBatchCommitment); // commitment

        uint256 totalBatchesCommitted = getters.getTotalBatchesCommitted();
        assertEq(totalBatchesCommitted, 1);
    }

    function test_SuccessfullyCommitBatchWithOneBlob() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.recordLogs();

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // batchNumber

        uint256 totalBatchesCommitted = getters.getTotalBatchesCommitted();
        assertEq(totalBatchesCommitted, 1);

        vm.clearMockedCalls();
    }

    function test_SuccessfullyCommitBatchWithTwoBlob() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 2;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes1");
        blobsLinearHashes[1] = Utils.randomBytes32("blobsLinearHashes2");

        bytes memory daInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = defaultBlobVersionedHashes[0];
        blobVersionedHashes[1] = defaultBlobVersionedHashes[0];

        bytes32 outputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        bytes[] memory correctL2Logs = Utils.createSystemLogs(outputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.operatorDAInput = daInput;

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);

        vm.recordLogs();

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(uint256(1))); // batchNumber

        uint256 totalBatchesCommitted = getters.getTotalBatchesCommitted();
        assertEq(totalBatchesCommitted, 1);

        vm.clearMockedCalls();
    }

    function test_RevertWhen_CommittingBatchMoreThanOneBatch() public {
        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](2);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[1] = correctNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(CanOnlyProcessOneBatch.selector));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_EmptyPubdataCommitments() public {
        bytes memory operatorDAInput = "\x01";

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.prank(validator);

        vm.expectRevert(
            abi.encodeWithSelector(OperatorDAInputTooSmall.selector, operatorDAInput.length, BLOB_DATA_OFFSET)
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_PartialPubdataCommitment() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;

        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory daInput = abi.encodePacked(
            Utils.randomBytes32("uncompressedStateDiffHash"),
            Utils.randomBytes32("totalL2PubdataHash"),
            uint8(1),
            blobsLinearHashes,
            bytes1(0x01),
            bytes("")
        );

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = daInput;

        vm.prank(validator);
        vm.blobhashes(defaultBlobVersionedHashes);

        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_TooManyPubdataCommitments() public {
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory daInput = abi.encodePacked(
            Utils.randomBytes32("uncompressedStateDiffHash"),
            Utils.randomBytes32("totalL2PubdataHash"),
            uint8(1),
            blobsLinearHashes,
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = daInput;

        vm.prank(validator);

        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_NotEnoughPubdataCommitments() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        bytes32[] memory versionedHashes = new bytes32[](2);
        versionedHashes[0] = defaultBlobVersionedHashes[0];
        versionedHashes[1] = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;

        vm.prank(validator);
        vm.blobhashes(versionedHashes);

        vm.expectRevert(abi.encodeWithSelector(NonEmptyBlobVersionHash.selector, uint256(1)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        vm.clearMockedCalls();
    }

    function test_RevertWhen_BlobDoesNotExist() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(EmptyBlobVersionHash.selector, 0));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        vm.clearMockedCalls();
    }

    function test_RevertWhen_SecondBlobSentWithoutCommitmentData() public {
        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = defaultBlobVersionedHashes[0];
        blobVersionedHashes[1] = defaultBlobVersionedHashes[0];

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);

        vm.expectRevert(abi.encodeWithSelector(NonEmptyBlobVersionHash.selector, uint256(1)));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);

        vm.clearMockedCalls();
    }

    function test_RevertWhen_SecondBlobLinearHashZeroWithCommitment() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 2;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes1");
        blobsLinearHashes[1] = bytes32(0);

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = defaultBlobVersionedHashes[0];
        blobVersionedHashes[1] = defaultBlobVersionedHashes[0];

        bytes32 outputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        bytes[] memory correctL2Logs = Utils.createSystemLogs(outputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.blobhashes(blobVersionedHashes);
        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(BlobHashCommitmentError.selector, uint256(1), true, false));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_SecondBlobLinearHashNotZeroWithEmptyCommitment() public {
        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 2;
        bytes32[] memory blobsLinearHashes = new bytes32[](2);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes1");
        blobsLinearHashes[1] = Utils.randomBytes32("blobsLinearHashes2");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            bytes1(0x01),
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = defaultBlobVersionedHashes[0];
        blobVersionedHashes[1] = defaultBlobVersionedHashes[0];

        bytes32 outputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        bytes[] memory correctL2Logs = Utils.createSystemLogs(outputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);

        IExecutor.CommitBatchInfo[] memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        vm.blobhashes(blobVersionedHashes);
        vm.prank(validator);

        // It will just panic with array out of bounds
        vm.expectRevert();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_commitBlockRealData() public {
        vm.prank(validator);
        vm.expectRevert();
        executor.commitBatchesSharedBridge(
            uint256(0),
            1,
            1,
            hex"010000000000000000000000000000000000000000000000000000000000000000d99a8d5b165650fc446e94cb537a51e410d3f16765a370ecc6de4e808d40763100000000000000000000000000000000000000000000000000000000000000520000000000000000000000000000000000000000000000000000000000000000c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009347b854344c5637ae228ed89c09dfd99c2045cc4cb4399fbce1ed1d6fe45cd7000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000680b788000000000000000000000000000000000000000000000000000000000000000b578a9516a82f53671ca9eb92e47ddb13dfcd410cdafd322e1e1ce4310c3fe38600000000000000000000000000000000000000000000000000000000000000007c1c19ba4f33fb20b7e628353aec6449026233b2f81dd44262389b5fc7c9e176a8d5e2c17a41dfede18efff66d8eb1a5d76e7a4f4cb60dc395bd4dbb359c6b27ee28538782646d08464ed41a3c5796a90b29b10992042806fd5dfc2694a11f23a00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000480000000000000000000000000000000000000000000000000000000000000031800000000000000000000000000000000000000000000800b0000000000000000000000000000000000000000000000000000000000000004d99a8d5b165650fc446e94cb537a51e410d3f16765a370ecc6de4e808d407631000100000000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000899a7a65fa68e8b745c1c98465b9095afaec3bc55b962286a12d50714265cb5b800000008000000000000000000000000000000000000800b0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000680b7880000000000000000000000000680b78820001000800000000000000000000000000000000000080010000000000000000000000000000000000000000000000000000000000000002c1c19ba4f33fb20b7e628353aec6449026233b2f81dd44262389b5fc7c9e176a000100080000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000070001000800000000000000000000000000000000000080010000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000000010008000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000007f94c232b453ddced4afe50f29b0f34a6dadee4e034e9761d013f331320d3dbe000100080000000000000000000000000000000000008008000000000000000000000000000000000000000000000000000000000000000600000000000000000000000044450ff37fbbd29b705514e9d0252a43f5ab634c00010008000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000055bbbc202d1ac5406b0a1c83cfe2c298b67856b34963c1020c9f1f0395e3faaf5000000000000000000000000000000000000000000000000000000000000000000000000000015429f8fcdf062a5557b8ded4c582abb8c2206c4f06712836f9ae5df2f25b32dd87514a26f3d5c29422c7a28bec94d86bab65e2fa36c7d20b8be7e5605f286bb26e001e50a381e2a2dfa8d4b42f1c59f320729e10c9fb287fbbb67b6588dec339c8e8a000000000800010000000000000000000000000000000000000000800199a7a65fa68e8b745c1c98465b9095afaec3bc55b962286a12d50714265cb5b80000000000000000000000000000000000000000000000000000000000000001000100010000000000000000000000000000000000008001c3d8e41a232a6e1644c7ec458af286a03e5aee0765f99e99ab5c2e579dbeb3d800000000000000000000000000000000000000000000000000000000000000010001000200000000000000000000000000000000000080013a93a155e1fb30d2d7d5f73b9bebd81c93fdc64f8e538c063f08bcdf903af73d00000000000000000000000000000000000000000000000000000000000000010001000300000000000000000000000000000000000080014735238b6dbf34c0ae1506a69f4c485d5ecd14a7b17b98c4e41db604da77b79b0000000000000000000000000000000000000000000000000000000000000001000100040000000000000000000000000000000000008001e54e93f3406d0e982010cb05bb1a47b8bb3b76244e5a5827947cfcabf3a1367c00000000000000000000000000000000000000000000000000000000000000010001000500000000000000000000000000000000000080016322e2c268d3cd5bf71210af81bafc7aa1f6486a3da2600ea9eed77ac6be1ea30000000000000000000000000000000000000000000000000000000000000001000100060000000000000000000000000000000000008001b03d9d52a51ae5229508dface30673e49d84ac85dca12be6826e4a589a593ca80000000000000000000000000000000000000000000000000000000000000001000100070000000000000000000000000000000000008001ae848202ab08b6303b34fe671aa187102485987c81a5623eea86bc531dc8ad7300000000000000000000000000000000000000000000000000000000000000010000000000000000010011ef04006339afb6556adc8321164b7fc53dd202f5c17e1c6d67de5fa79da423b4e6ac556b000100053bbba85436dbcc1fb22f25b049387ffab263d62aa4548b5fd90576555561084487e289dcd8583393ff0f4aeb9ad384399e0a0f168083fb00ceb177fece00010000b7d3bd727d9d759611bf4b85f08a9899c51a626eb3cd06627719d6f3ffb7131da3b1f069ca082776d4b17fa48d4a1f7b21ac95646202780ba8fc0750c9000100014b71adee1c18588b50320637a120674a4b52d784f61898605b9703b70e3e15b6d66acf8a6583b782973872192cdfad0f8c06fbdb3e8c9ccf1ac8cbf50400010004ed9559c2440c158f459ea20a833993c2f1f32831852fa394241c635a56b4b56d270111dfc967303ff3b99711a3ed2206922d001401fe2f2bd7b2987d2d0001000067c8f08a2d59a92ce17db2352c63c62b526ec71654de14f2a4c1515ffaf82a5af4f5220b4dcdd575ba21ba75c8e6c93106e86d9f37d5bb13b9bdb2ba0d00010001490c1476510fa5cf427e77e16b960754d2a646825dde419ceb304781318c9394a0f1aea20de1ef8385396f946762db244cb25e81ff1a4158719a0204d5000100001b6ba6acccad1a7a6c741dc9e443da33d5fa9da454086d4851acb24a925b37dd3451013a3cfcce728b5213de4ea3d5e0c056111578d4c9aafb1d673cd4000100021582b2e2c3cb5285a4b4c50f520e57be52b683080d843c276f8dedf88b80a28b94e9008d4fc32962126c62b9b40d10c2188d2936516c0ac41a67c4fd58000100014933ef7362855d577377ed32240318abadf5c99087f23b098799716b09dd772d9789aafda85a99711d7ab3322c1db5458942f9dcdf9af782a3eebb8e97000100005b41f2919102e8a880c36f0bca54616a70724ef43c399dda22e154d42a24840e9fa2f11426489178db2a7607539a175b38d357ecff8a2bf33fb7a032f5890100000000000000000000000000000000009fba854be2fdebad326f136f88dbf4b172d64d1ced33b4ab63a4941ce249978905000000000000000000000000000000004b0a6ea5e9c5689e7f464ac5a825eacb5c140ec4cb7493ecfbdd0c4e7fe5ea6c890100000000000000000000000000000000b122c7fecb9e7a4d3f165c48f52d26b378eb638c20fcfaccf8c8288a2970ac99890100000000000000000000000000000000c9ac710af3437fc2f4f9308332a4480a58514c2d951c497772ae8e8d8408af1b890200000000000000000000000000000000fc57424e085e9118906e999b3cd2678431a359fb4578c855e6cb38552f19347f0901af9093a77fa836a66841a6686051fe59c27f222e1ddb7da751fba40984683e6b090187e327e1d21d333e2675fd74a8cd5053074e01eb54d66f1e959d7e98abb88bb50901c230f045c51552038f7716f6bd3d3b719fe8d8bf56d4705e4d25ad608d31a9ed09010f8811d0771f7935b86fe34bbd23a41c31191c95a9f7603e3a82f9f198ee5ace09010efcffddcf5ae2876b955749e9e00b4a5b601658fb5bbdd79d61f341df158dbe09014c6a711d08f4f78362766b7e4d9c55d6aa7e8dfef010fcf57d9e22029d613b3709015e09b746a87703c6366a12419cafa624cbb920a79ec2edd22fed8a029d0fc8e20901db0f9264d1dc264e185b0daa08fa7e83c39f5b7c7b6d373afec5a3286756a259090141ff3d21bd14409ef3af1578d795bff3407eee659addf0b66de43f07ae569ba809011d7f623af83814adddaf0fe267c5efed79bd15ee240689a17a2df53db862336609015910c6290d5e590277a91c50b368421526fc1092a39f7a44eaa1a596fb8b39040052f431aa35dd80982e3c66614112503ca2c6e344745f4a2bcfc9bd7e09c755844357d6137874932f4eecb25f171701abc5b53fc534a2e0dd5ddf23f3f88a64d719010002d9f84922ed979ebab2e2e1ea3abada07afae3cb9f8f8191c339a3da8d54df2a90052f431aa35dd80982e3c66614112503ca2c6e344745f4a2bcfc9bd7e09c755840f8bd4ddd2646366f1100b466138f239bff5d58313416339174930a37263ff55a17162d77e09acce9b6bb8699d89c4019e5009708b3caae87f35113aad8ef759f7cf957786400e9e5212e7bcb3a3590bae512b2e99090977e46b2c35d93db6567dbda9516d20f98bd4ea48901887765979d8db18cf42a811010ed505474c502a104d691b65324f4c26e8a737864f80fb712123744dfe1c06b0000052f431aa35dd80982e3c66614112503ca2c6e344745f4a2bcfc9bd7e09c7558481e37bcd284c26e5b511355d44642c8b3d387fa50c82479ef4b4e07c4f463ca100010000f19fe3d23f00b76182de22621ebfa3102a6bd0dde3162a78d75b32c2866eb174849e7407b14df08a52d4d4f12b3608014b2a68f305f149e23c48a9022919010003497f9621d41e83ab5a1cddaa3516b0d2519a92a05143bcb8070df0a96133e6b50964476fa7b3dfe56b2ddfb864cf67106aead91978339c0c8e1cba04866eb61cbf0b09093171a1982878eabc3d3666fb91dcb9b19e659bbabf69681feebe20f0e6fda5c1a1820ffa28845795975cc218b544faee7e74be85c53ea9ffeecd5e63d2a21fd5559ee9dfe7ae12f14d1a85ff4b28be41a31a3035c419010002d1a74591028bcb5cbb2e041eda00554db003fdc949e5945ce539203bf40c6d60090971e91721f9918576d760f02f03cac47c6f4003316031848e3c1d99e6e83a47434103ac0c4c4f918000b9d39653fd741afd381653cc461e7acbdd8654fb278d8a11f69fd41fecef4bc94103240ad7114ef100a374b73dae298fc64e33caf951fda182eb8feaa77014c9fec68f90884d50d14839860289d154d240f56bef200af87b62c9f5db6c168798ab3ba384ee63d6e30b0914e9ca2c5b1b253901feeb6cedbcc0a25420c1d9d705358c134cc601d9d184cb4dfdde7e1cac2bc3d4d38bf9ec44e62105f5e100123bafc586f77764488cd24c6a77546e5a0fe8bdfb4fa203cfaffc36cce4dd5b8901000000000000000000000000680b78808e7dd06ac5b73b473be6bc5a51030f4c7437657cb7b29bf376c564b8d1675a5e8902000000000000000000000000680b78824ba84e1f37d041bc6e55ba396826cc494e84d4815b6db52690422eea7386314f00e8e77626586f73b955364c7b4bbf0bb7f7685ebd40e852b164633a4acbd3244c3de2202ccb626ad387d70722e64fbe44562e2f231a290c08532b8d6aba402ff500632b64a0ceace9f051794aea98d3239c74b63721b9c907cf9369252bf829af0d79093588d0e847efa73a10ce20e4799fb1e46642d65617c7e5213fa04989d92d8902000000000000000000000000680b788287ded247e1660f827071c7f1371934589751085384fc9f4462c1f1897c5c3eef89010000000000000000000000000000000186248193eb4dd2a8ce815f876c124d48359522f0854d95d8072eaff0d37d55bd1103203e890d6c2c3bada6eecc9603a99c1c6259ed5a6402f1c76cc18b568c3aefba0f1111d7911dd2ad743ff237d411648a0fe32c6d74eec060716a2a74352f6b1c435b5d6700d99a8d5b165650fc446e94cb537a51e410d3f16765a370ecc6de4e808d407631d674f636a35a6f1a51564ec3371b9c4da3126d5ad0bae350cfc7faeac76363b809ff6862f6666c5507fc3315d684239e0226706b45c3417291f5b7acc2d339505211a118189c6759d123bc484568760f300d8648cf0b70b444f47736ce88a24e6b50fb051dc0ae5db3af44d908f6dcd9a015d04a7ee1e3190100033bace016ae0a41e7a9ed09a85b21556d26bbf2f24b4c20a54bbba51b5f53a29e19010005ed24849ecaa883ab6a20d64face094960f474966d9a213b70275c070c44cb522a15630df57abe6af4a94e98997143a798bc26f36413e886b11b9a1cf31af89234598e28f605cc10232ec4885b4bde8975d84bba1ea0901ba9ade58f8aa6ca82bf22a2b480ff5ddece8a6e86351a47b10d58f3380fbdbb70901478768ebfaa85d7e0cddea19f79e66957162e481513bef321251c20218e554ec0901b790876b74405a443d8a34b2f46014ed6005345a9e81accc27af37124a491dde09ff243106565d0c4fcef8975e79b1b2230c019f4e3ab27a3f4e7ca9306b9f629984a118189c6759d123bc484568760f300d8648cf0b70c775c1733755abf522addbd697e2d70a5b61464bd1681b298951c4f60d8ec70c190100040a5e8b831cdb74653042091c0f70a7a4aad52e55457c944cc33b89c1ce5f5d73090126b67a3001a2cdda5f34ac92de51c7c12ab2e4698558d65389ed42e677fa055509fffd2705ee58cf3ce5ee5c1ce03f466d7e9836bc4712baa299153d8447ca7971cfa118189c6759d123bc484568760f300d8648cf0b70bf0eaf67aee349ebb15976a36fedac1a4a0665503ad3717ff3fe6ae078b3659ca15e1836835846056f01ee9145ef8458ca916f78f3a84a028d69ced021a4bd8c5b2624a8f250d912b8f8f59d8155f95e5ee58a652609ff47ea1fc23ae86f586ef17771ebe9bf37676a15af61c94de48d3471f06519a35209015fc0715fd8f215eb7c10e3f550d9b209f18caa8740af541bd346ef49648b14f50901c9a9147bcefba88d2140af6af6b913b935657d35055705b807155b3dd0822a83090133b98f829e691c8cc802c27b1ba8c2d63ea8dd729e161fcc60c6e3db903eb05a0901e49f0b9bfbc4b9c8790e7bd53bcfe3263827f13f383ca02cb43467fb919b8d000901f04de1282ad4afaf9f13edc7cccc86ddc60bf9fd770a5da4f0ba7f0d28ff8290090110bba356077f1d7feca1bf135b2c1cf646a6506039d2b4f2b2945a136a79a75111010fc8dd27f8430f0c1b6a23d89a4d606e150261362d7ea3feab0fd1db1ab92cd7930046700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21e69d1cbae2e87463b7dfee7b4bcb8752291e8f2bc82539105cee56a9c2f0f21300e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf7594417290a256e1d097c6d7d698b9fb90c3014e155b114848fd30d32e1dd01cb05a80046700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21f77cbe685f8e7eef44db45a5a1ed8187a505ecefe3548cf0120481435f7d74fe090195318cfda129d679516f051aba9579fae1b8de017e9fb75bc22f55378d6ab90809ff12c354bdc34429b809152b6c5b7800e9cf3954d4036128799cb5f1ab5cb968bba118189c6759d123bc484568760f300d8648cf0b70479a09368179467e11823e24aca01ea2f3a78da5027f955aa125410e15084971a14e5234a447a32d547b0d1c9b944e1243cab54e2b6aeca192d70ba1e7295330e28777fda1bda6d8f4a429aeb73fc956aa0d5aeaf60903fda85e059054efd16c3d1908b6d25bc41d46330c3df0a521854fc7f5c144420100577261707065642045746865720000000000000000000000000000000000001a9d7e2aacd6c65966b3829a9d82412558bd3cc781d78e07bb6c9465ee58d31ad9005745544800000000000000000000000000000000000000000000000000000008ea57ea3c523faf893242cd7aa4d352cac5739ee8b0c0a7c42ae415f23962b77100577261707065642045746865720000000000000000000000000000000000001a20c2b662bcff085a2cb517b4bef32231a54b3dd01256827dc00a4dd7545b6d75003100000000000000000000000000000000000000000000000000000000000002c45b58c8346b1d0539621f78ac41112fdfd710db4651f19e9acb92e9cd94541e1901000388049deada8525251bbb270610709487f55483863532974d01a8e92a0374ed160901ff50a606972a1b26ac6ca4197e87ee3abd14f02c73d1c7ac35c8044d273272ae1901000479a651f10853f4efa877e59fda3d6d19895b5e757d97abf29cdfaf96bcb66d830052f431aa35dd80982e3c66614112503ca2c6e344745f4a2bcfc9bd7e09c7558426f79ccb6ec525eaf5b373543d1b5881d0c07e3ed944954363353bad528f52bc190100077c82a2d8d25092dc655a1f243e7959dd552e530776fc72a07a3a1dc1c7f8a2e3a118189c6759d123bc484568760f300d8648cf0b7009ee683448a74c50f4adc34567bc2534b962620a50339735e02588162392971e0901e678ea43875ebe8f84f0510220cd9843337ce10cb27891d7da9d397c8ee3dda2a125bb6f94624236bed93de9f0910ddcb5380384891bc1370231f749f56c3dd1b3684b63ba7c2aa558e7cbe57fa8bd2a01f6a6ab90a10fc1e58dc251d61d59124c606115f7428f76ca22383d2898ea3752cfdf5adc247e1930c698e966b3935fca91f04404f95edb0acaa118189c6759d123bc484568760f300d8648cf0b700000004e0901214b689eaf555916bfe06caf5ab7d67b8fc43426507fbb8d51e7b30517eb844b000000000000000000000000000000000000000000000000000000000000"
        );
    }

    function test_executeBlockRealData() public {
        vm.prank(validator);
        vm.chainId(506);
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRoot.historicalRoot.selector, uint256(19)),
            abi.encode(0x491972b6512222d97150fa321c666ea768ea6ea6bee7b2a50a4a745cb713df2a)
        );
        vm.expectRevert();
        // executor.executeBatchesSharedBridge(
        //     uint256(271),
        //     7,
        //     7,
        //     hex"01000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000754637665a79b0a5f704c9d7874cf23110c2d2248e72dfcdf248596b802bb05ce00000000000000000000000000000000000000000000000000000000000001030000000000000000000000000000000000000000000000000000000000000000c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4700000000000000000000000000000000000000000000000000000000000000000b6e530ff878093b2d0caf87780451a8f07922570e2d820b7a8541114e0d70fb500000000000000000000000000000000000000000000000000000000680b6c4c90e742459a5931889c1a303128141c5e8fc0dce78097325b719a1d4893a79917000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001fa000000000000000000000000000000000000000000000000000000000000001300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001491972b6512222d97150fa321c666ea768ea6ea6bee7b2a50a4a745cb713df2a"
        // );
        executor.executeBatchesSharedBridge(
            uint256(271),
            10,
            10,
            hex"01000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000af201dcbc213d01796f7e03682f9cde98a9e338927f0454ee46ed0bc5518dba1d000000000000000000000000000000000000000000000000000000000000011500000000000000000000000000000000000000000000000000000000000000018b02fa911ea9bbc744667a86d03a40f0b3a22e9fd5b6424965fbf3423cdd9fe000000000000000000000000000000000000000000000000000000000000000006b0d433a4080daa862f268f8e2e33c20a99635144c6f562de0fe579a3d1e831f00000000000000000000000000000000000000000000000000000000680b857401d6d0fe8848ff2b84855b45a028f83e02f45d61e3718ac98cea38a641aed099000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000040c37858db682740fe01fbd85c7cc11fe0b59d8ff3c6136318c5763747283ede5cb106385af87d6bf0fa184d312d3395411b8dc6990375583570fe1aa1bab1d6900000000000000000000000000000000000000000000000000000000000000003afe924ade2f9475276684e9d7f7f9d5453695806451dcc53b9a0e04b3287e8b000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fadbd3c7f79fa2bdc4f24857709cd4a4e870623dc9e9abcdfd6e448033e35212000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000013f29862a4219393ce2f10d0f9e61fdbc984c364c96d61b3b80ac33ad092e0498000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    struct MessageRoot {
        uint256 chainId;
        uint256 blockNumber;
        // We double overloading this. The sides normally contain the root, as well as the sides.
        // Second overloading: if the length is 1, we are importing a chainBatchRoot/messageRoot instead of sides.
        bytes32[] sides;
    }

    function test_recalculateMsgRootRollingHash() public {
        MessageRoot[] memory msgRoots = new MessageRoot[](2);
        MessageRoot memory msgRoot1 = MessageRoot({chainId: 260, blockNumber: 1, sides: new bytes32[](1)});
        msgRoot1.sides[0] = 0xfb2eb93318710c98f501f6ff6b11c373baccd0ffcaefe15f97debe09cb7939e1;
        msgRoots[0] = msgRoot1;
        MessageRoot memory msgRoot2 = MessageRoot({chainId: 506, blockNumber: 17, sides: new bytes32[](1)});
        msgRoot2.sides[0] = 0xf83b13aa476ef3253e6acff5779276da7924fabaec9a8c39274cf021efe1255a;
        msgRoots[1] = msgRoot2;
        bytes32 rollingHash = 0x0000000000000000000000000000000000000000000000000000000000000000;
        for (uint256 i = 0; i < msgRoots.length; i++) {
            MessageRoot memory msgRoot = msgRoots[i];
            console.logBytes(
                abi.encodePacked(
                    rollingHash,
                    msgRoot.chainId,
                    msgRoot.blockNumber,
                    uint256(96),
                    msgRoot.sides.length,
                    msgRoot.sides
                )
            );
            rollingHash = keccak256(
                abi.encodePacked(
                    rollingHash,
                    msgRoot.chainId,
                    msgRoot.blockNumber,
                    uint256(96),
                    msgRoot.sides.length,
                    msgRoot.sides
                )
            );
        }
        console.logBytes32(rollingHash);
    }
}
