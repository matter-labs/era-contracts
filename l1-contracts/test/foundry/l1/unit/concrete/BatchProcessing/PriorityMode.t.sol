// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    InvalidTxCountInPriorityMode,
    NotCompatibleWithPriorityMode,
    PriorityModeActivationTooEarly,
    PriorityModeIsNotAllowed,
    PriorityModeRequiresPermanentRollup,
    PriorityOpsRequestTimestampMissing,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {DepositsPaused} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {PRIORITY_EXPIRATION} from "contracts/common/Config.sol";

contract PriorityModeExecutorTest is ExecutorTest {
    function test_revertWhen_activatePriorityMode_notAllowed() public {
        vm.expectRevert(PriorityModeIsNotAllowed.selector);
        admin.activatePriorityMode();
    }

    function test_revertWhen_activatePriorityMode_notPermanentRollup() public {
        _requestPriorityOp();
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();

        vm.expectRevert(PriorityModeRequiresPermanentRollup.selector);
        admin.activatePriorityMode();
    }

    function test_revertWhen_permanentlyAllowPriorityMode_noPriorityTxs() public {
        vm.prank(owner);
        admin.makePermanentRollup();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PriorityOpsRequestTimestampMissing.selector, 0));
        admin.permanentlyAllowPriorityMode();
    }

    /// @dev Regression test (AIH-431): the admin pauses deposits first and then permanently allows Priority Mode.
    /// Without the guard, the chain would advertise the escape hatch while no user can submit a new
    /// priority transaction, and once the queue drains `activatePriorityMode` can never be triggered.
    function test_revertWhen_permanentlyAllowPriorityMode_depositsPaused() public {
        vm.prank(owner);
        admin.makePermanentRollup();
        _requestPriorityOp();

        vm.prank(owner);
        migrator.pauseDepositsBeforeInitiatingMigration();
        assertEq(utilsFacet.util_getPausedDepositsTimestamp(), block.timestamp);

        vm.prank(owner);
        vm.expectRevert(DepositsPaused.selector);
        admin.permanentlyAllowPriorityMode();

        assertFalse(utilsFacet.util_getPriorityModeCanBeActivated());
    }

    /// @dev Once the admin unpauses deposits, Priority Mode can be allowed, and from then on deposits
    /// cannot be paused again, so the pause and Priority Mode can never coexist in either order.
    function test_permanentlyAllowPriorityMode_afterDepositsUnpaused() public {
        vm.prank(owner);
        admin.makePermanentRollup();
        _requestPriorityOp();

        vm.prank(owner);
        migrator.pauseDepositsBeforeInitiatingMigration();

        // `unpauseDeposits` asks the bridgehub's chain asset handler whether a migration is in progress.
        dummyBridgehub.setChainAssetHandler(address(chainAssetHandler));
        vm.prank(owner);
        migrator.unpauseDeposits();
        assertEq(utilsFacet.util_getPausedDepositsTimestamp(), 0);

        vm.expectEmit(true, true, true, true, address(admin));
        emit IAdmin.PriorityModeAllowed();
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();
        assertTrue(utilsFacet.util_getPriorityModeCanBeActivated());

        vm.prank(owner);
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        migrator.pauseDepositsBeforeInitiatingMigration();
        assertEq(utilsFacet.util_getPausedDepositsTimestamp(), 0);
    }

    function test_revertWhen_activatePriorityMode_tooEarly() public {
        vm.prank(owner);
        admin.makePermanentRollup();

        vm.warp(100);
        uint256 requestTimestamp = _requestPriorityOp();

        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();

        uint256 earliest = requestTimestamp + PRIORITY_EXPIRATION;

        vm.warp(earliest - 1);
        vm.expectRevert(abi.encodeWithSelector(PriorityModeActivationTooEarly.selector, earliest, earliest - 1));
        admin.activatePriorityMode();
    }

    function test_revertWhen_validatorCommitsInPriorityMode() public {
        _activatePriorityMode();

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        committer.commitBatchesSharedBridge(address(0), 0, 0, "");
    }

    function test_revertWhen_priorityModeBatchHasL2Txs() public {
        _activatePriorityMode();

        _mockDAForCommit(newCommitBatchInfoZKsyncOS.batchNumber);

        uint256 l2TxCount = 1;
        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.numberOfLayer2Txs = l2TxCount;
        commitInfo.numberOfLayer1Txs = 1;

        CommitBatchInfoZKsyncOS[] memory commitInfos = new CommitBatchInfoZKsyncOS[](1);
        commitInfos[0] = commitInfo;

        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesDataZKsyncOS(
            genesisStoredBatchInfo,
            commitInfos
        );

        vm.prank(address(permissionlessValidator));
        vm.expectRevert(abi.encodeWithSelector(InvalidTxCountInPriorityMode.selector, l2TxCount, 1));
        committer.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);
    }

    function test_revertWhen_priorityModeBatchHasNoL1Txs() public {
        _activatePriorityMode();

        _mockDAForCommit(newCommitBatchInfoZKsyncOS.batchNumber);

        CommitBatchInfoZKsyncOS memory commitInfo = newCommitBatchInfoZKsyncOS;
        commitInfo.numberOfLayer2Txs = 0;
        commitInfo.numberOfLayer1Txs = 0;

        CommitBatchInfoZKsyncOS[] memory commitInfos = new CommitBatchInfoZKsyncOS[](1);
        commitInfos[0] = commitInfo;

        (uint256 commitFrom, uint256 commitTo, bytes memory commitData) = Utils.encodeCommitBatchesDataZKsyncOS(
            genesisStoredBatchInfo,
            commitInfos
        );

        vm.prank(address(permissionlessValidator));
        vm.expectRevert(abi.encodeWithSelector(InvalidTxCountInPriorityMode.selector, 0, 0));
        committer.commitBatchesSharedBridge(address(0), commitFrom, commitTo, commitData);
    }

    function _activatePriorityMode() internal {
        vm.prank(owner);
        admin.makePermanentRollup();
        _requestPriorityOp();
        vm.prank(owner);
        admin.permanentlyAllowPriorityMode();
        vm.warp(block.timestamp + PRIORITY_EXPIRATION + 1);
        admin.activatePriorityMode();
    }
}
