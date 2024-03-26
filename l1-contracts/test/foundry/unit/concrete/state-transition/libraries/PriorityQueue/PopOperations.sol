// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityQueueSharedTest} from "./_PriorityQueue_Shared.t.sol";
import {PriorityOperation} from "contracts/dev-contracts/test/PriorityQueueTest.sol";

contract PopOperationsTest is PriorityQueueSharedTest {
    uint256 public constant NUMBER_OPERATIONS = 10;

    function setUp() public {
        push_mock_entries(NUMBER_OPERATIONS);
    }

    function test_after_pop() public {
        assertEq(NUMBER_OPERATIONS, priorityQueue.getSize());

        PriorityOperation memory front = priorityQueue.popFront();
        assertEq(keccak256(abi.encode(0)), front.canonicalTxHash);
        assertEq(uint64(0), front.expirationTimestamp);
        assertEq(uint192(0), front.layer2Tip);

        assertEq(NUMBER_OPERATIONS - 1, priorityQueue.getSize());
        assertEq(1, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getTotalPriorityTxs());
        assertFalse(priorityQueue.isEmpty());

        // Ok - one more pop
        PriorityOperation memory front2 = priorityQueue.popFront();
        assertEq(keccak256(abi.encode(1)), front2.canonicalTxHash);
        assertEq(uint64(1), front2.expirationTimestamp);
        assertEq(uint192(1), front2.layer2Tip);

        assertEq(NUMBER_OPERATIONS - 2, priorityQueue.getSize());
        assertEq(2, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getTotalPriorityTxs());
        assertFalse(priorityQueue.isEmpty());
    }

    function test_pop_until_limit() public {
        for (uint256 i = 0; i < NUMBER_OPERATIONS; ++i) {
            PriorityOperation memory front = priorityQueue.popFront();
            assertEq(keccak256(abi.encode(i)), front.canonicalTxHash);
        }

        assertEq(0, priorityQueue.getSize());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getTotalPriorityTxs());
        assertTrue(priorityQueue.isEmpty());

        // And now let's push something.

        PriorityOperation memory dummyOp = PriorityOperation({
            canonicalTxHash: keccak256(abi.encode(300)),
            expirationTimestamp: uint64(300),
            layer2Tip: uint192(300)
        });
        priorityQueue.pushBack(dummyOp);

        assertEq(1, priorityQueue.getSize());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(NUMBER_OPERATIONS + 1, priorityQueue.getTotalPriorityTxs());
        assertFalse(priorityQueue.isEmpty());

        PriorityOperation memory front_end = priorityQueue.popFront();
        assertEq(keccak256(abi.encode(300)), front_end.canonicalTxHash);
        assertTrue(priorityQueue.isEmpty());

        // And now let's go over the limit and fail.
        vm.expectRevert(bytes.concat("s"));
        priorityQueue.popFront();
    }
}
