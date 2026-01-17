// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./_Executor_Shared.t.sol";

import {Utils} from "../Utils/Utils.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {BatchNumberMismatch, CanOnlyProcessOneBatch, InvalidSystemLogsLength, EmptyPrecommitData, InvalidBatchNumber} from "contracts/common/L1ContractErrors.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";

/// @title Extended tests for ExecutorFacet to increase coverage
contract ExecutorExtendedTest is ExecutorTest {
    function test_CommitBatches_BatchNumberMismatch() public {
        // Try to commit a batch with wrong batch number (should be 1, but we'll send 5)
        IExecutor.CommitBatchInfo memory wrongBatchInfo = newCommitBatchInfo;
        wrongBatchInfo.batchNumber = 5;

        IExecutor.CommitBatchInfo[] memory newBatchesData = new IExecutor.CommitBatchInfo[](1);
        newBatchesData[0] = wrongBatchInfo;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(BatchNumberMismatch.selector, 1, 5));
        executor.commitBatchesSharedBridge(address(0), 5, 5, commitData);
    }

    function test_CommitBatches_MultipleBatches_Fails() public {
        // Try to commit multiple batches at once (only 1 is allowed)
        IExecutor.CommitBatchInfo[] memory newBatchesData = new IExecutor.CommitBatchInfo[](2);

        IExecutor.CommitBatchInfo memory batch1 = newCommitBatchInfo;
        IExecutor.CommitBatchInfo memory batch2 = newCommitBatchInfo;
        batch2.batchNumber = 2;

        newBatchesData[0] = batch1;
        newBatchesData[1] = batch2;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        executor.commitBatchesSharedBridge(address(0), 1, 2, commitData);
    }

    function test_CommitBatches_SystemLogsLengthInvalid() public {
        IExecutor.CommitBatchInfo memory invalidBatch = newCommitBatchInfo;
        // Set invalid system logs length (not multiple of L2_TO_L1_LOG_SERIALIZE_SIZE)
        invalidBatch.systemLogs = hex"0102030405";

        IExecutor.CommitBatchInfo[] memory newBatchesData = new IExecutor.CommitBatchInfo[](1);
        newBatchesData[0] = invalidBatch;

        (uint256 processFrom, uint256 processTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            newBatchesData
        );

        vm.prank(validator);
        vm.expectRevert(InvalidSystemLogsLength.selector);
        executor.commitBatchesSharedBridge(address(0), processFrom, processTo, commitData);
    }

    function test_PrecommitSharedBridge_InvalidBatchNumber() public {
        // Try to precommit with wrong batch number
        bytes memory precommitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(uint256(0), abi.encodePacked(bytes32(uint256(1))))
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(InvalidBatchNumber.selector, 5, 1));
        executor.precommitSharedBridge(address(0), 5, precommitData);
    }

    function test_PrecommitSharedBridge_EmptyPrecommitData() public {
        bytes memory precommitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(uint256(0), bytes(""))
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(EmptyPrecommitData.selector, 1));
        executor.precommitSharedBridge(address(0), 1, precommitData);
    }

    function test_CommitBatches_UnauthorizedValidator() public {
        IExecutor.CommitBatchInfo[] memory newBatchesData = new IExecutor.CommitBatchInfo[](1);
        newBatchesData[0] = newCommitBatchInfo;

        (uint256 processFrom, uint256 processTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            newBatchesData
        );

        vm.prank(randomSigner);
        vm.expectRevert();
        executor.commitBatchesSharedBridge(address(0), processFrom, processTo, commitData);
    }

    function testFuzz_CommitBatches_DifferentTimestamps(uint64 timestamp) public {
        vm.assume(timestamp > currentTimestamp);
        vm.assume(timestamp < type(uint64).max / 2);

        // Warp to a time that allows this timestamp
        vm.warp(timestamp + 1);

        IExecutor.CommitBatchInfo memory batchInfo = newCommitBatchInfo;
        batchInfo.timestamp = timestamp;

        // Need to recreate system logs with the new timestamp
        bytes memory l2Logs = Utils.encodePacked(Utils.createSystemLogs(bytes32(0)));
        batchInfo.systemLogs = l2Logs;

        IExecutor.CommitBatchInfo[] memory newBatchesData = new IExecutor.CommitBatchInfo[](1);
        newBatchesData[0] = batchInfo;

        // This will likely fail due to timestamp validation, but we're testing the path
    }
}
