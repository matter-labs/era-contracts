// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriorityQueueTest, PriorityOperation} from "contracts/dev-contracts/test/PriorityQueueTest.sol";

contract PriorityQueueSharedTest is Test {
    PriorityQueueTest internal priorityQueue;

    constructor() {
        priorityQueue = new PriorityQueueTest();
    }

    // Pushes 'count' entries into the priority queue.
    function push_mock_entries(uint256 count) public {
        for (uint256 i = 0; i < count; ++i) {
            PriorityOperation memory dummyOp = PriorityOperation({
                canonicalTxHash: keccak256(abi.encode(i)),
                expirationTimestamp: uint64(i),
                layer2Tip: uint192(i)
            });
            priorityQueue.pushBack(dummyOp);
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
