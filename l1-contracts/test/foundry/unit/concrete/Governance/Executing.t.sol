// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";

import {GovernanceTest} from "./_Governance_Shared.t.sol";

import {IGovernance} from "contracts/governance/IGovernance.sol";

contract ExecutingTest is GovernanceTest {
    using stdStorage for StdStorage;

    function test_ScheduleTransparentAndExecute() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 1000);
        vm.warp(block.timestamp + 1000);
        executeOpAndCheck(op);
    }

    function test_ScheduleTransparentAndExecuteInstant() public {
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        vm.prank(owner);
        governance.scheduleTransparent(op, 1000000);
        vm.prank(securityCouncil);
        executeInstantOpAndCheck(op);
    }

    function test_ScheduleShadowAndExecute() public {
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        bytes32 opId = governance.hashOperation(op);
        vm.startPrank(owner);
        governance.scheduleShadow(opId, 100000);
        vm.warp(block.timestamp + 100000);
        vm.startPrank(securityCouncil);
        executeOpAndCheck(op);
    }

    function test_ScheduleShadowAndExecuteInstant() public {
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        bytes32 opId = governance.hashOperation(op);
        vm.startPrank(owner);
        governance.scheduleShadow(opId, 100000);
        vm.startPrank(securityCouncil);
        executeInstantOpAndCheck(op);
    }

    function test_RevertWhen_ExecutingOperationBeforeDeadline() public {
        vm.startPrank(owner);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(eventOnFallback), 0, "");
        governance.scheduleTransparent(op, 10000);
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(op);
    }

    function test_RevertWhen_ExecutingOperationWithDifferentTarget() public {
        vm.startPrank(owner);
        IGovernance.Operation memory validOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        governance.scheduleTransparent(validOp, 0);

        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(address(0), 0, "");
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ExecutingOperationWithDifferentValue() public {
        vm.startPrank(owner);
        IGovernance.Operation memory validOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        governance.scheduleTransparent(validOp, 0);

        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            1,
            ""
        );
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ExecutingOperationWithDifferentData() public {
        vm.startPrank(owner);
        IGovernance.Operation memory validOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        governance.scheduleTransparent(validOp, 0);

        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "00"
        );
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ExecutingOperationWithDifferentPredecessor() public {
        vm.startPrank(owner);
        // Executing one operation to get a valid executed predecessor
        IGovernance.Operation memory executedOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        governance.scheduleTransparent(executedOp, 0);
        executeOpAndCheck(executedOp);

        // Schedule operation with 0 predecessor
        IGovernance.Operation memory validOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        governance.scheduleTransparent(validOp, 0);

        // Schedule operation with predecessor of `executedOp` operation
        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        invalidOp.predecessor = governance.hashOperation(executedOp);

        // Failed to execute operation that wasn't scheduled
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ExecutingOperationWithDifferentSalt() public {
        vm.startPrank(owner);
        IGovernance.Operation memory validOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        governance.scheduleTransparent(validOp, 0);

        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            ""
        );
        invalidOp.salt = Utils.randomBytes32("wrongSalt");
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ExecutingOperationWithNonExecutedPredecessor() public {
        vm.startPrank(owner);

        IGovernance.Operation memory invalidOp = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        invalidOp.predecessor = Utils.randomBytes32("randomPredecessor");
        governance.scheduleTransparent(invalidOp, 0);
        vm.expectRevert("Predecessor operation not completed");
        governance.execute(invalidOp);
    }

    function test_RevertWhen_ScheduleOperationOnceAndExecuteTwice() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        governance.scheduleTransparent(op, 0);
        executeOpAndCheck(op);

        vm.expectRevert("Operation must be ready before execution");
        governance.execute(op);
    }

    function test_RevertWhen_ExecutingNonScheduledOperation() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(op);
    }

    function test_RevertWhen_ExecutingInstantNonScheduledOperation() public {
        vm.startPrank(securityCouncil);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        vm.expectRevert("Operation must be pending before execution");
        governance.executeInstant(op);
    }

    function test_RevertWhen_ExecutingOperationAfterCanceling() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        governance.scheduleTransparent(op, 0);
        governance.cancel(governance.hashOperation(op));
        vm.expectRevert("Operation must be ready before execution");
        governance.execute(op);
    }

    function test_ExecutingOperationAfterRescheduling() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        governance.scheduleTransparent(op, 0);
        governance.cancel(governance.hashOperation(op));
        governance.scheduleTransparent(op, 0);
        executeOpAndCheck(op);
    }

    function test_RevertWhen_ExecutingOperationTwice() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "1122"
        );
        governance.scheduleTransparent(op, 0);
        executeOpAndCheck(op);
        vm.expectRevert("Operation with this proposal id already exists");
        governance.scheduleTransparent(op, 0);
    }

    function test_RevertWhen_ExecutingOperationFailed() public {
        vm.startPrank(owner);

        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(revertFallback), 0, "");
        governance.scheduleTransparent(op, 0);
        vm.expectRevert(bytes(""));
        governance.execute(op);
    }

    function test_CancelExistingOperation() public {
        vm.startPrank(owner);

        governance.scheduleShadow(bytes32(0), 0);
        governance.cancel(bytes32(0));
    }

    function test_RevertWhen_CancelNonExistingOperation() public {
        vm.startPrank(owner);

        vm.expectRevert("Operation must be pending");
        governance.cancel(bytes32(0));
    }

    function test_RevertWhen_ScheduleOperationWithDelayLessThanMinimumOne() public {
        vm.startPrank(owner);
        stdstore.target(address(governance)).sig(governance.minDelay.selector).checked_write(1000);
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(revertFallback), 0, "");

        vm.expectRevert("Proposed delay is less than minimum delay");
        governance.scheduleTransparent(op, 0);
    }
}
