// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {GovernanceTest} from "./_Governance_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IGovernance} from "../../../../../cache/solpp-generated-contracts/governance/IGovernance.sol";

contract OperationStatusTest is GovernanceTest {
    function test_RandomIdIsNotOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperation = governance.isOperation(randomId);
        require(!isOperation, "Should not be operation");
    }

    function test_RandomIdIsNotPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationPending = governance.isOperationPending(randomId);
        require(!isOperationPending, "Should not be pending operation");
    }

    function test_RandomIdIsNotReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationReady = governance.isOperationReady(randomId);
        require(!isOperationReady, "Should not be ready operation");
    }

    function test_RandomIdIsNotDoneOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationDone = governance.isOperationDone(randomId);
        require(!isOperationDone, "Should not be done operation");
    }

    function test_RandomIdIsHasUnsetStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        IGovernance.OperationState opState = governance.getOperationState(randomId);
        require(opState == IGovernance.OperationState.Unset, "Operation status should be Unset");
    }

    function test_ScheduledOperationIsOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperation = governance.isOperation(randomId);
        require(isOperation, "Should be operation");
    }

    function test_ScheduledOperationIsPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationPending = governance.isOperationPending(randomId);
        require(isOperationPending, "Should be pending operation");
    }

    function test_ScheduledOperationIsNotReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationReady = governance.isOperationReady(randomId);
        require(!isOperationReady, "Should not be ready operation");
    }

    function test_ScheduledOperationIsNotDone() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationDone = governance.isOperationDone(randomId);
        require(!isOperationDone, "Should not be done operation");
    }

    function test_ScheduledOperationHasWaitingStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        IGovernance.OperationState opState = governance.getOperationState(randomId);
        require(opState == IGovernance.OperationState.Waiting, "Operation status is not Waiting");
    }

    function test_ScheduledOperationAfterDelayIsOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperation = governance.isOperation(randomId);
        require(isOperation, "Should be operation");
    }

    function test_ScheduledOperationAfterDelayIsPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationPending = governance.isOperationPending(randomId);
        require(isOperationPending, "Should be pending operation");
    }

    function test_ScheduledOperationAfterDelayIsReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationReady = governance.isOperationReady(randomId);
        require(isOperationReady, "Operation should be ready");
    }

    function test_ScheduledOperationAfterDelayIsNotDone() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationDone = governance.isOperationDone(randomId);
        require(!isOperationDone, "Operation should not be done");
    }

    function test_ScheduledOperationAfterDelayHasReadyStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        IGovernance.OperationState opState = governance.getOperationState(randomId);
        require(opState == IGovernance.OperationState.Ready, "Operation status should be Ready");
    }

    function test_ProcessedOperationIsOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperation = governance.isOperation(opId);
        require(isOperation, "Should be operation");
    }

    function test_ScheduledOperationAfterDelayIsNotPendingOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationPending = governance.isOperationPending(opId);
        require(!isOperationPending, "Should not be pending operation");
    }

    function test_ProcessedOperationAfterDelayIsNotReadyOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationReady = governance.isOperationReady(opId);
        require(!isOperationReady, "Should be not ready operation");
    }

    function test_ProcessedOperationAfterDelayIsDone() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationDone = governance.isOperationDone(opId);
        require(isOperationDone, "Operation should be done");
    }

    function test_ProcessedOperationAfterDelayHasReadyStatus() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        IGovernance.OperationState opState = governance.getOperationState(opId);
        require(opState == IGovernance.OperationState.Done, "Operation status should be done");
    }
}
