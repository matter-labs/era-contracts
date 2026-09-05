// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {
    InvalidTxCountInPriorityMode,
    PriorityModeActivationTooEarly,
    PriorityModeIsNotAllowed,
    PriorityModeRequiresPermanentRollup,
    PriorityOpsRequestTimestampMissing,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {PRIORITY_EXPIRATION, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";

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

    function _requestPriorityOp() internal returns (uint256 requestTimestamp) {
        address prioritySender = makeAddr("prioritySender");
        uint256 l2GasLimit = 1_000_000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(10_000_000, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        vm.deal(prioritySender, baseCost);
        requestTimestamp = block.timestamp;
        vm.prank(prioritySender);
        dummyBridgehub.requestL2TransactionDirect{value: baseCost}(
            L2TransactionRequestDirect({
                chainId: l2ChainId,
                mintValue: baseCost,
                l2Contract: makeAddr("l2Contract"),
                l2Value: 0,
                l2Calldata: "",
                l2GasLimit: l2GasLimit,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                refundRecipient: prioritySender
            })
        );
    }
}
