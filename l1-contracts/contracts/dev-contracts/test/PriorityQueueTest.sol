// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityQueue, PriorityOperation} from "../../state-transition/libraries/PriorityQueue.sol";

contract PriorityQueueTest {
    PriorityQueue.Queue priorityQueue;

    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return PriorityQueue.getFirstUnprocessedPriorityTx(priorityQueue);
    }

    function getTotalPriorityTxs() external view returns (uint256) {
        return PriorityQueue.getTotalPriorityTxs(priorityQueue);
    }

    function getSize() external view returns (uint256) {
        return PriorityQueue.getSize(priorityQueue);
    }

    function isEmpty() external view returns (bool) {
        return PriorityQueue.isEmpty(priorityQueue);
    }

    function pushBack(PriorityOperation memory _operation) external {
        return PriorityQueue.pushBack(priorityQueue, _operation);
    }

    function front() external view returns (PriorityOperation memory) {
        return PriorityQueue.front(priorityQueue);
    }

    function popFront() external returns (PriorityOperation memory operation) {
        return PriorityQueue.popFront(priorityQueue);
    }
}
