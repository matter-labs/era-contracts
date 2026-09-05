// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./_Executor_Shared.t.sol";

import {Utils} from "../Utils/Utils.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    BatchNumberMismatch,
    CanOnlyProcessOneBatch,
    RevertedBatchNotAfterNewLastBatch,
    CantRevertExecutedBatch,
    InvalidProtocolVersion
} from "contracts/common/L1ContractErrors.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";

/// @title Extended tests for ExecutorFacet to increase coverage
contract ExecutorExtendedTest is ExecutorTest {
    function test_CommitBatches_BatchNumberMismatch() public {
        // Try to commit a batch with wrong batch number (should be 1, but we'll send 5)
        CommitBatchInfoZKsyncOS memory wrongBatchInfo = newCommitBatchInfoZKsyncOS;
        wrongBatchInfo.batchNumber = 5;

        CommitBatchInfoZKsyncOS[] memory newBatchesData = new CommitBatchInfoZKsyncOS[](1);
        newBatchesData[0] = wrongBatchInfo;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(BatchNumberMismatch.selector, 1, 5));
        committer.commitBatchesSharedBridge(address(0), 5, 5, commitData);
    }

    function test_CommitBatches_MultipleBatches_Fails() public {
        // Try to commit multiple batches at once (only 1 is allowed)
        CommitBatchInfoZKsyncOS[] memory newBatchesData = new CommitBatchInfoZKsyncOS[](2);

        CommitBatchInfoZKsyncOS memory batch1 = newCommitBatchInfoZKsyncOS;
        CommitBatchInfoZKsyncOS memory batch2 = newCommitBatchInfoZKsyncOS;
        batch2.batchNumber = 2;

        newBatchesData[0] = batch1;
        newBatchesData[1] = batch2;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        committer.commitBatchesSharedBridge(address(0), 1, 2, commitData);
    }

    function test_CommitBatches_UnauthorizedValidator() public {
        CommitBatchInfoZKsyncOS[] memory newBatchesData = new CommitBatchInfoZKsyncOS[](1);
        newBatchesData[0] = newCommitBatchInfoZKsyncOS;

        (uint256 processFrom, uint256 processTo, bytes memory commitData) = Utils.encodeCommitBatchesDataZKsyncOS(
            genesisStoredBatchInfo,
            newBatchesData
        );

        vm.prank(randomSigner);
        vm.expectRevert();
        committer.commitBatchesSharedBridge(address(0), processFrom, processTo, commitData);
    }
}

/// @title Extended tests for ExecutorFacet revert batches functionality
contract ExecutorRevertBatchesTest is ExecutorTest {
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

        CommitBatchInfoZKsyncOS[] memory newBatchesData = new CommitBatchInfoZKsyncOS[](1);
        newBatchesData[0] = newCommitBatchInfoZKsyncOS;

        bytes memory commitData = bytes.concat(
            bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT),
            abi.encode(genesisStoredBatchInfo, newBatchesData)
        );

        vm.prank(validator);
        vm.expectRevert(InvalidProtocolVersion.selector);
        committer.commitBatchesSharedBridge(address(0), 1, 1, commitData);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
