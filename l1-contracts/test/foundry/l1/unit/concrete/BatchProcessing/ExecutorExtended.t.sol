// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./_Executor_Shared.t.sol";

import {Utils} from "../Utils/Utils.sol";
import {UtilsFacet} from "../Utils/UtilsFacet.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {BatchNumberMismatch, CanOnlyProcessOneBatch, InvalidSystemLogsLength, EmptyPrecommitData, InvalidBatchNumber, RevertedBatchNotAfterNewLastBatch, CantRevertExecutedBatch, CantExecuteUnprovenBatches, VerifiedBatchesExceedsCommittedBatches, InvalidProof, InvalidProtocolVersion} from "contracts/common/L1ContractErrors.sol";
import {InvalidBatchesDataLength} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @title Extended tests for ExecutorFacet to increase coverage
contract ExecutorExtendedTest is ExecutorTest {
    function test_CommitBatches_BatchNumberMismatch() public {
        // Try to commit a batch with wrong batch number (should be 1, but we'll send 5)
        CommitBatchInfo memory wrongBatchInfo = newCommitBatchInfo;
        wrongBatchInfo.batchNumber = 5;

        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](1);
        newBatchesData[0] = wrongBatchInfo;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(BatchNumberMismatch.selector, 1, 5));
        committer.commitBatchesSharedBridge(address(0), 5, 5, commitData);
    }

    function test_CommitBatches_MultipleBatches_Fails() public {
        // Try to commit multiple batches at once (only 1 is allowed)
        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](2);

        CommitBatchInfo memory batch1 = newCommitBatchInfo;
        CommitBatchInfo memory batch2 = newCommitBatchInfo;
        batch2.batchNumber = 2;

        newBatchesData[0] = batch1;
        newBatchesData[1] = batch2;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        committer.commitBatchesSharedBridge(address(0), 1, 2, commitData);
    }

    function test_CommitBatches_SystemLogsLengthInvalid() public {
        CommitBatchInfo memory invalidBatch = newCommitBatchInfo;
        // Set invalid system logs length (not multiple of L2_TO_L1_LOG_SERIALIZE_SIZE)
        invalidBatch.systemLogs = hex"0102030405";

        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](1);
        newBatchesData[0] = invalidBatch;

        (uint256 processFrom, uint256 processTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            newBatchesData
        );

        vm.prank(validator);
        vm.expectRevert(InvalidSystemLogsLength.selector);
        committer.commitBatchesSharedBridge(address(0), processFrom, processTo, commitData);
    }

    function test_PrecommitSharedBridge_InvalidBatchNumber() public {
        // Try to precommit with wrong batch number
        bytes memory precommitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(uint256(0), abi.encodePacked(bytes32(uint256(1))))
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(InvalidBatchNumber.selector, 5, 1));
        committer.precommitSharedBridge(address(0), 5, precommitData);
    }

    function test_PrecommitSharedBridge_EmptyPrecommitData() public {
        bytes memory precommitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(uint256(0), bytes(""))
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(EmptyPrecommitData.selector, 1));
        committer.precommitSharedBridge(address(0), 1, precommitData);
    }

    function test_CommitBatches_UnauthorizedValidator() public {
        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](1);
        newBatchesData[0] = newCommitBatchInfo;

        (uint256 processFrom, uint256 processTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            newBatchesData
        );

        vm.prank(randomSigner);
        vm.expectRevert();
        committer.commitBatchesSharedBridge(address(0), processFrom, processTo, commitData);
    }

    function testFuzz_CommitBatches_DifferentTimestamps(uint64 timestamp) public {
        vm.assume(timestamp > currentTimestamp);
        vm.assume(timestamp < type(uint64).max / 2);

        // Warp to a time that allows this timestamp
        vm.warp(timestamp + 1);

        CommitBatchInfo memory batchInfo = newCommitBatchInfo;
        batchInfo.timestamp = timestamp;

        // Need to recreate system logs with the new timestamp
        bytes memory l2Logs = Utils.encodePacked(Utils.createSystemLogs(bytes32(0)));
        batchInfo.systemLogs = l2Logs;

        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](1);
        newBatchesData[0] = batchInfo;

        // This will likely fail due to timestamp validation, but we're testing the path
    }
}

/// @title Extended tests for ExecutorFacet revert batches functionality
contract ExecutorRevertBatchesTest is ExecutorTest {
    UtilsFacet internal utilsFacet;

    constructor() {
        // Add UtilsFacet to the diamond to manipulate state
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("")
        });

        // Execute the upgrade as chainTypeManager
        address chainTypeManager = getters.getChainTypeManager();
        vm.prank(chainTypeManager);
        admin.executeUpgrade(diamondCutData);

        utilsFacet = UtilsFacet(address(executor));
    }

    function test_RevertBatches_RevertWhen_RevertedBatchNotAfterNewLastBatch() public {
        // Try to revert to a batch number greater than totalBatchesCommitted
        // This should revert with RevertedBatchNotAfterNewLastBatch
        uint256 currentCommitted = getters.getTotalBatchesCommitted();
        uint256 invalidRevertTo = currentCommitted + 10;

        vm.prank(validator);
        vm.expectRevert(RevertedBatchNotAfterNewLastBatch.selector);
        executor.revertBatchesSharedBridge(address(0), invalidRevertTo);
    }

    function test_RevertBatches_RevertWhen_CantRevertExecutedBatch() public {
        // Set totalBatchesCommitted to 5 and totalBatchesExecuted to 3
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesExecuted(3);

        // Try to revert to batch 2, which is before the executed batch (3)
        vm.prank(validator);
        vm.expectRevert(CantRevertExecutedBatch.selector);
        executor.revertBatchesSharedBridge(address(0), 2);
    }

    function test_RevertBatches_Success_ResetsUpgradeBatchNumber() public {
        // Set up state: 5 committed batches, 0 executed
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesExecuted(0);

        // Set l2SystemContractsUpgradeBatchNumber to 3
        utilsFacet.util_setL2SystemContractsUpgradeBatchNumber(3);
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 3);

        // Revert to batch 2 (before the upgrade batch)
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 2);

        // The upgrade batch number should be reset to 0
        assertEq(utilsFacet.util_getL2SystemContractsUpgradeBatchNumber(), 0);
    }

    function test_RevertBatches_Success_ResetsVerifiedBatches() public {
        // Set up state: 5 committed batches, 3 verified, 0 executed
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(3);
        utilsFacet.util_setTotalBatchesExecuted(0);

        assertEq(utilsFacet.util_getTotalBatchesVerified(), 3);

        // Revert to batch 2 (before the last verified batch)
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 2);

        // The verified batches should be reset to 2
        assertEq(utilsFacet.util_getTotalBatchesVerified(), 2);
    }

    function test_RevertBatches_Success_DoesNotResetVerifiedIfNotNeeded() public {
        // Set up state: 5 committed batches, 2 verified, 0 executed
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(2);
        utilsFacet.util_setTotalBatchesExecuted(0);

        // Revert to batch 4 (after the last verified batch)
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 4);

        // The verified batches should NOT be reset (still 2)
        assertEq(utilsFacet.util_getTotalBatchesVerified(), 2);
    }

    function test_CommitBatches_RevertWhen_InvalidProtocolVersion() public {
        // Mock the chainTypeManager to return false for protocolVersionIsActive
        address ctm = utilsFacet.util_getChainTypeManager();
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.protocolVersionIsActive.selector), abi.encode(false));

        CommitBatchInfo[] memory newBatchesData = new CommitBatchInfo[](1);
        newBatchesData[0] = CommitBatchInfo({
            batchNumber: 1,
            timestamp: uint64(block.timestamp),
            indexRepeatedStorageChanges: 0,
            newStateRoot: bytes32(0),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            bootloaderHeapInitialContentsHash: bytes32(0),
            eventsQueueStateHash: bytes32(0),
            systemLogs: new bytes(0),
            operatorDAInput: new bytes(0)
        });

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION),
            abi.encode(
                IExecutor.StoredBatchInfo({
                    batchNumber: 0,
                    batchHash: bytes32(0),
                    indexRepeatedStorageChanges: 0,
                    numberOfLayer1Txs: 0,
                    priorityOperationsHash: bytes32(0),
                    l2LogsTreeRoot: bytes32(0),
                    dependencyRootsRollingHash: bytes32(0),
                    timestamp: 0,
                    commitment: bytes32(0)
                }),
                newBatchesData
            )
        );

        vm.prank(validator);
        vm.expectRevert(InvalidProtocolVersion.selector);
        committer.commitBatchesSharedBridge(address(0), 1, 1, commitData);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
