// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";

import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {TESTNET_COMMIT_TIMESTAMP_NOT_OLDER} from "contracts/common/Config.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {RevertedBatchNotAfterNewLastBatch} from "contracts/common/L1ContractErrors.sol";

contract RevertingTest is ExecutorTest {
    uint256 private constant MAX_REVERT_BATCHES_GAS = 300_000;

    function setUp() public {
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.firstBlockTimestamp = uint64(currentTimestamp);
        commitInfo.lastBlockTimestamp = uint64(currentTimestamp);

        newStoredBatchInfo = _commitOSBatchGetStored(genesisStoredBatchInfo, commitInfo);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(address(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_RevertingMoreBatchesThanAlreadyCommitted() public {
        vm.prank(validator);
        vm.expectRevert(RevertedBatchNotAfterNewLastBatch.selector);
        executor.revertBatchesSharedBridge(address(0), 10);
    }

    function test_SuccessfulRevert() public {
        uint256 totalBlocksCommittedBefore = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommittedBefore, 1, "totalBlocksCommittedBefore");

        uint256 totalBlocksVerifiedBefore = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerifiedBefore, 1, "totalBlocksVerifiedBefore");

        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        uint256 totalBlocksCommitted = getters.getTotalBlocksCommitted();
        assertEq(totalBlocksCommitted, 0, "totalBlocksCommitted");

        uint256 totalBlocksVerified = getters.getTotalBlocksVerified();
        assertEq(totalBlocksVerified, 0, "totalBlocksVerified");
    }

    function test_RevertBatchesGasBound() public {
        vm.prank(validator);
        uint256 gasBefore = gasleft();
        executor.revertBatchesSharedBridge(address(0), 0);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, MAX_REVERT_BATCHES_GAS, "revertBatchesSharedBridge gas too high");
    }
}
