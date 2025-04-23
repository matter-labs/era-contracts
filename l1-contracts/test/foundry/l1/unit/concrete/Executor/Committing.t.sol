// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS, L2_TO_L1_MESSENGER} from "../Utils/Utils.sol";
import {ExecutorTest, EMPTY_PREPUBLISHED_COMMITMENT, POINT_EVALUATION_PRECOMPILE_RESULT} from "./_Executor_Shared.t.sol";

import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {L2_PUBDATA_CHUNK_PUBLISHER_ADDR} from "contracts/common/L2ContractAddresses.sol";
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

        vm.expectRevert(abi.encodeWithSelector(MissingSystemLogs.selector, 127, 125));
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
            abi.encodePacked(bytes2(0x0001), bytes2(0x0000), L2_SYSTEM_CONTEXT_ADDRESS, uint256(119), bytes32(""))
        );

        IExecutor.CommitBatchInfo memory wrongNewCommitBatchInfo = newCommitBatchInfo;
        wrongNewCommitBatchInfo.systemLogs = abi.encodePacked(wrongL2Logs);

        IExecutor.CommitBatchInfo[] memory wrongNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        wrongNewCommitBatchInfoArray[0] = wrongNewCommitBatchInfo;

        vm.prank(validator);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedSystemLog.selector, uint256(119)));
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

            uint256 allLogsProcessed = uint256(127);
            vm.expectRevert(abi.encodeWithSelector(MissingSystemLogs.selector, 127, allLogsProcessed ^ (1 << i)));
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
        vm.mockCall(blobVersionedHashRetriever, abi.encode(uint256(0)), abi.encode(bytes32(0)));

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
}
