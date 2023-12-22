pragma solidity 0.8.20;

import {PriorityQueueSharedTest} from "./_PriorityQueue_Shared.t.sol";
import {PriorityOperation} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/PriorityQueueTest.sol";

contract PushOperationsTest is PriorityQueueSharedTest {
    uint public constant NUMBER_OPERATIONS = 10;

    function setUp() public {
        push_mock_entries(NUMBER_OPERATIONS);
    }

    function test_front() public {
        assertEq(NUMBER_OPERATIONS, priorityQueue.getSize());
        PriorityOperation memory front = priorityQueue.front();
        assertEq(keccak256(abi.encode(0)), front.canonicalTxHash);
        assertEq(uint64(0), front.expirationTimestamp);
        assertEq(uint192(0), front.layer2Tip);
        // This is 'front' and not popFront, so the amount should not change.
        assertEq(NUMBER_OPERATIONS, priorityQueue.getSize());
        assertEq(0, priorityQueue.getFirstUnprocessedPriorityTx());
        assertEq(NUMBER_OPERATIONS, priorityQueue.getTotalPriorityTxs());
        assertFalse(priorityQueue.isEmpty());
    }
}
