// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Utils} from "../Utils/Utils.sol";

import {GovernanceTest} from "./_Governance_Shared.t.sol";

import {IGovernance} from "contracts/governance/IGovernance.sol";

contract OperationStatusTest is GovernanceTest {
    function test_RandomIdIsNotOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperation = governance.isOperation(randomId);
        assertFalse(isOperation);
    }

    function test_RandomIdIsNotPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationPending = governance.isOperationPending(randomId);
        assertFalse(isOperationPending);
    }

    function test_RandomIdIsNotReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationReady = governance.isOperationReady(randomId);
        assertFalse(isOperationReady);
    }

    function test_RandomIdIsNotDoneOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        bool isOperationDone = governance.isOperationDone(randomId);
        assertFalse(isOperationDone);
    }

    function test_RandomIdIsHasUnsetStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        IGovernance.OperationState opState = governance.getOperationState(randomId);
        assertTrue(opState == IGovernance.OperationState.Unset);
    }

    function test_ScheduledOperationIsOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperation = governance.isOperation(randomId);
        assertTrue(isOperation);
    }

    function test_ScheduledOperationIsPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationPending = governance.isOperationPending(randomId);
        assertTrue(isOperationPending);
    }

    function test_ScheduledOperationIsNotReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationReady = governance.isOperationReady(randomId);
        assertFalse(isOperationReady);
    }

    function test_ScheduledOperationIsNotDone() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        bool isOperationDone = governance.isOperationDone(randomId);
        assertFalse(isOperationDone);
    }

    function test_ScheduledOperationHasWaitingStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);

        IGovernance.OperationState opState = governance.getOperationState(randomId);
        assertTrue(opState == IGovernance.OperationState.Waiting);
    }

    function test_ScheduledOperationAfterDelayIsOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperation = governance.isOperation(randomId);
        assertTrue(isOperation);
    }

    function test_ScheduledOperationAfterDelayIsPendingOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationPending = governance.isOperationPending(randomId);
        assertTrue(isOperationPending);
    }

    function test_ScheduledOperationAfterDelayIsReadyOperation() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationReady = governance.isOperationReady(randomId);
        assertTrue(isOperationReady);
    }

    function test_ScheduledOperationAfterDelayIsNotDone() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        bool isOperationDone = governance.isOperationDone(randomId);
        assertFalse(isOperationDone);
    }

    function test_ScheduledOperationAfterDelayHasReadyStatus() public {
        bytes32 randomId = Utils.randomBytes32("randomId");
        vm.prank(owner);
        governance.scheduleShadow(randomId, 1000);
        vm.warp(block.timestamp + 1000);

        IGovernance.OperationState opState = governance.getOperationState(randomId);
        assertTrue(opState == IGovernance.OperationState.Ready);
    }

    function test_ProcessedOperationIsOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperation = governance.isOperation(opId);
        assertTrue(isOperation);
    }

    function test_ScheduledOperationAfterDelayIsNotPendingOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationPending = governance.isOperationPending(opId);
        assertFalse(isOperationPending);
    }

    function test_ProcessedOperationAfterDelayIsNotReadyOperation() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationReady = governance.isOperationReady(opId);
        assertFalse(isOperationReady);
    }

    function test_ProcessedOperationAfterDelayIsDone() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        bool isOperationDone = governance.isOperationDone(opId);
        assertTrue(isOperationDone);
    }

    function test_ProcessedOperationAfterDelayHasReadyStatus() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);

        bytes32 opId = governance.hashOperation(op);
        IGovernance.OperationState opState = governance.getOperationState(opId);
        assertTrue(opState == IGovernance.OperationState.Done);
    }
}
