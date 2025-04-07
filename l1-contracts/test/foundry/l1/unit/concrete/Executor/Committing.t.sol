// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_ADDRESS, L2_TO_L1_MESSENGER} from "../Utils/Utils.sol";
import {ExecutorTest, EMPTY_PREPUBLISHED_COMMITMENT, POINT_EVALUATION_PRECOMPILE_RESULT} from "./_Executor_Shared.t.sol";

import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {SystemLogKey} from "contracts/common/Config.sol";
import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {L2_PUBDATA_CHUNK_PUBLISHER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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

            uint256 allLogsProcessed = uint256(255);
            vm.expectRevert(abi.encodeWithSelector(MissingSystemLogs.selector, 255, allLogsProcessed ^ (1 << i)));
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

        assertEq(entries.length, 2);
        assertEq(entries[1].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[1].topics[1], bytes32(uint256(1))); // batchNumber
        assertEq(entries[1].topics[2], correctNewCommitBatchInfo.newStateRoot); // batchHash
        assertEq(entries[1].topics[3], expectedBatchCommitment); // commitment

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

        assertEq(entries.length, 2);
        assertEq(entries[1].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[1].topics[1], bytes32(uint256(1))); // batchNumber

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

        assertEq(entries.length, 2);
        assertEq(entries[1].topics[0], keccak256("BlockCommit(uint256,bytes32,bytes32)"));
        assertEq(entries[1].topics[1], bytes32(uint256(1))); // batchNumber

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

    function test_commitBlockRealData() public {
        vm.prank(validator);
        executor.commitBatchesSharedBridge(
            uint256(0),
            1,
            1,
            hex"000000000000000000000000000000000000000000000000000000000000000000ecc950f901cc7c79c2b9460b9884d90a495f9950c61c8df844595e76ff5a982500000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000000c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000098216171d0efa92c5af0b521f1c8188b4b4f980fbf37bb3a8114772fd0fc783b00000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000067ea8081000000000000000000000000000000000000000000000000000000000000023992c6e30833aa00cdec07d4899aac400b55ae8af98d77a6e370ba0958b963fb5c00000000000000000000000000000000000000000000000000000000000000220aabc5da5fd2baa4d0ffbee1e350ce12f85591627fa428041ee74fd98365f13f4072228977d613dc19887413678ff9f3a0d01c00701c26a9bd219006b231fe4dd5231eeb0b5b24962bcc3022286b5cf0c300326bb3b3475c47de7809354dbd1b00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000480000000000000000000000000000000000000000000000000000000000000031800000000000000000000000000000000000000000000800b0000000000000000000000000000000000000000000000000000000000000004ecc950f901cc7c79c2b9460b9884d90a495f9950c61c8df844595e76ff5a9825000100000000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000702fa5779ecc950f901cc7c79c2b9460b9884d90a495f9950c61c8df844595e7600010000000000000000000000000000000000000000800100000000000000000000000000000000000000000000000000000000000000087f7de4f9583f59f9c8a522c0f8c531bfd52a7a3c7bba51b28966e248d237c4e000000023000000000000000000000000000000000000800b000000000000000000000000000000000000000000000000000000000000000100000000000000000000000067ea808100000000000000000000000067ea808300010023000000000000000000000000000000000000800100000000000000000000000000000000000000000000000000000000000000020aabc5da5fd2baa4d0ffbee1e350ce12f85591627fa428041ee74fd98365f13f0001002300000000000000000000000000000000000080010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000002200010023000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000000acb709490e52a0fc5d2f6115dcad4c8502a7e54365142d2ba5ff52f9c500ee1000100230000000000000000000000000000000000008008000000000000000000000000000000000000000000000000000000000000000600000000000000000000000044450ff37fbbd29b705514e9d0252a43f5ab634c00010023000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000059fb6ac12df71db797feb14ecaa1ac80339ddd2fb2a1dd9aeb3805b155ce816a00000000000000000000000000000000000000000000000000000000000000000000000000000011246eaf4e667922fee348e97876ca432267fb47477b1c6b930561d721b0baa71fa2343945cf5ac8f075f40820f8f954f5ee666a876049f9487be2a92855162cf5301842dcce91ec6118a0dbb0f5a705259ff2568bca31ce2ef0ca266cbe94c28315c01b62ad393bb2e716263eeda2fcc4e584e11dec82cd891698e74d33eb625be3c8196dbba112ae89e8a95b4d22dff1dcb4ead08bf80b156c6b47f6bd05b296f9f95f5b300bb5083ba86ab5f0910a7aa25d101647620215a73a5761cd5f119590ec5931e6689e5c7b6ebe1e56557dffeee3f485c13370830d290a834b41a5afac232b751a7bd8e88a9918e16ae83af2b307500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    function test_executeBlockRealData() public {
        vm.prank(validator);
        executor.executeBatchesSharedBridge(
            uint256(271),
            2,
            2,
            hex"00000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002822adb9638d944da651929c483888f295dad6ba6d82be35ab865879bac59fefa00000000000000000000000000000000000000000000000000000000000000b900000000000000000000000000000000000000000000000000000000000000014a28c82cdd2bef8f821192e9c04ca360b8049442be34212f04a90b9f8de7b4d5aa783b0b0588911ff8f1bf467d4b1e6e5f0e4ba7396bb44f3ce5424b685e213a19d10213710ce71e87ce9ec4bd24dd5557f372fd30fe375fbaafe3bd5969f0030000000000000000000000000000000000000000000000000000000067ec4f76bec2d13e01da35e6047ab3ec736d8098087a1431e64aab6d99c6580c4da6a4a6000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000004ae848202ab08b6303b34fe671aa187102485987c81a5623eea86bc531dc8ad7306a23e438ce807cd551f5d126dd9c48273c07ad26e9fa988329d10901626c68062f784161a84f8977c3f8fa83ced9efae70bc7eef93d29d06940084f00c73b9500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000454a4be7e94ec018be27bb1fbfe5db17f64aff25e93f359ea69ba53c845b1c5000000000000000000000000000000000000000000000000000000000000000014c8c59e7d5ff4d21e7a28317224c5784b0cf0369fef063900d7a7f573ccc8f57000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000104000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001fb2eb93318710c98f501f6ff6b11c373baccd0ffcaefe15f97debe09cb7939e100000000000000000000000000000000000000000000000000000000000001fa000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001f83b13aa476ef3253e6acff5779276da7924fabaec9a8c39274cf021efe1255a"
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
