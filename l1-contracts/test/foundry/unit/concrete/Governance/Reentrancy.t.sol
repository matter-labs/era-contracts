// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable max-line-length

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {GovernanceTest} from "./_Governance_Shared.t.sol";

import {IGovernance} from "contracts/governance/IGovernance.sol";
import {ReenterGovernance} from "contracts/dev-contracts/test/ReenterGovernance.sol";

contract ReentrancyTest is GovernanceTest {
    using stdStorage for StdStorage;

    function test_ExecuteOperationWithReentrancy() public {
        // Set governance owner to be equal to the forwarder contract.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(forwarder));
        vm.startPrank(address(forwarder));

        // Schedule operation, but don't execute it.
        IGovernance.Operation memory op1 = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "eeeeeee"
        );
        governance.scheduleTransparent(op1, 0);

        // Prepare data for the second operation, which will call forwarder
        // to reenter governance with the execution of the first operation.
        bytes memory executeData = abi.encodeCall(IGovernance.execute, (op1));
        bytes memory forwardData = abi.encodeCall(forwarder.forward, (address(governance), executeData));
        IGovernance.Operation memory op2 = operationWithOneCallZeroSaltAndPredecessor(
            address(forwarder),
            0,
            forwardData
        );
        // Schedule & execute the second operation.
        governance.scheduleTransparent(op2, 0);
        governance.execute(op2);
        // Check that both operations were executed.
        assertTrue(governance.isOperationDone(governance.hashOperation(op2)));
        assertTrue(governance.isOperationDone(governance.hashOperation(op1)));
    }

    function test_ExecuteInstantOperationWithReentrancy() public {
        // Set governance owner & security council to be equal to the forwarder contract.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(forwarder));
        vm.startPrank(address(forwarder));
        stdstore.target(address(governance)).sig(governance.securityCouncil.selector).checked_write(address(forwarder));
        vm.startPrank(address(forwarder));

        // Schedule operation, but don't execute it.
        IGovernance.Operation memory op1 = operationWithOneCallZeroSaltAndPredecessor(
            address(eventOnFallback),
            0,
            "eeeeeee"
        );
        governance.scheduleTransparent(op1, 0);

        // Prepare data for the second operation, which will call forwarder
        // to reenter governance with the execution of the first operation.
        bytes memory executeData = abi.encodeCall(IGovernance.execute, (op1));
        bytes memory forwardData = abi.encodeCall(forwarder.forward, (address(governance), executeData));
        IGovernance.Operation memory op2 = operationWithOneCallZeroSaltAndPredecessor(
            address(forwarder),
            0,
            forwardData
        );
        // Schedule & execute instant the second operation.
        governance.scheduleTransparent(op2, 0);
        governance.executeInstant(op2);
        // Check that both operations were executed.
        assertTrue(governance.isOperationDone(governance.hashOperation(op2)));
        assertTrue(governance.isOperationDone(governance.hashOperation(op1)));
    }

    function test_RevertedWith_ExecuteTheSameOperationTwice() public {
        // Initialize contract that will reenter Governance on executing operation.
        ReenterGovernance reenterGovernance = new ReenterGovernance();
        // Grant owner access for reenterGovernance.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(reenterGovernance));

        // Schedule operation, that will reenter `Governance.execute` for the same op.
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(reenterGovernance), 0, "");
        reenterGovernance.initialize(governance, op, ReenterGovernance.FunctionToCall.Execute);

        vm.startPrank(address(reenterGovernance));

        governance.scheduleTransparent(op, 0);
        vm.expectRevert("Operation must be ready after execution");
        governance.execute(op);
    }

    function test_RevertedWith_ExecuteInstantTheSameOperationTwice() public {
        // Initialize contract that will reenter Governance on executing operation.
        ReenterGovernance reenterGovernance = new ReenterGovernance();
        // Grant owner and security council access for reenterGovernance.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(reenterGovernance));
        stdstore.target(address(governance)).sig(governance.securityCouncil.selector).checked_write(
            address(reenterGovernance)
        );

        // Schedule operation, that will reenter `Governance.executeInstant` for the same op.
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(reenterGovernance), 0, "");
        reenterGovernance.initialize(governance, op, ReenterGovernance.FunctionToCall.ExecuteInstant);

        vm.startPrank(address(reenterGovernance));

        governance.scheduleTransparent(op, 0);
        vm.expectRevert("Operation must be pending after execution");
        governance.executeInstant(op);
    }

    function test_RevertedWith_ExecuteOperationThatWillCancelItself() public {
        // Initialize contract that will reenter Governance on executing operation.
        ReenterGovernance reenterGovernance = new ReenterGovernance();
        // Grant owner access for reenterGovernance.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(reenterGovernance));

        // Schedule operation, that will reenter `Governance.execute` for the same op.
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(reenterGovernance), 0, "");
        reenterGovernance.initialize(governance, op, ReenterGovernance.FunctionToCall.Cancel);

        vm.startPrank(address(reenterGovernance));

        governance.scheduleTransparent(op, 0);
        vm.expectRevert("Operation must be ready after execution");
        governance.execute(op);
    }

    function test_RevertedWith_ExecuteInstantOperationThatWillCancelItself() public {
        // Initialize contract that will reenter Governance on executing operation.
        ReenterGovernance reenterGovernance = new ReenterGovernance();
        // Grant owner and security council access for reenterGovernance.
        stdstore.target(address(governance)).sig(governance.owner.selector).checked_write(address(reenterGovernance));
        stdstore.target(address(governance)).sig(governance.securityCouncil.selector).checked_write(
            address(reenterGovernance)
        );

        // Schedule operation, that will reenter `Governance.executeInstant` for the same op.
        IGovernance.Operation memory op = operationWithOneCallZeroSaltAndPredecessor(address(reenterGovernance), 0, "");
        reenterGovernance.initialize(governance, op, ReenterGovernance.FunctionToCall.Cancel);

        vm.startPrank(address(reenterGovernance));

        governance.scheduleTransparent(op, 0);
        vm.expectRevert("Operation must be pending after execution");
        governance.executeInstant(op);
    }
}
