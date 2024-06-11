// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityQueueSharedTest} from "./_PriorityQueue_Shared.t.sol";

contract OnEmptyQueueTest is PriorityQueueSharedTest {
    function test_gets() public {
        assertEq(0, priorityQueue.getSize());
        assertEq(0, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(0, priorityQueue.getTotalPriorityTxs());
        assertTrue(priorityQueue.isEmpty());
    }

    function test_failGetFront() public {
        vm.expectRevert(bytes("D"));
        priorityQueue.front();
    }

    function test_failPopFront() public {
        vm.expectRevert(bytes("s"));
        priorityQueue.popFront();
    }
}
