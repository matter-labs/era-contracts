// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/libraries/PriorityQueue.sol";

contract PriorityQueueTest {
    using PriorityQueue for PriorityQueue.Queue;

    PriorityQueue.Queue priorityQueue;

    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return priorityQueue.getFirstUnprocessedPriorityTx();
    }

    function getTotalPriorityTxs() external view returns (uint256) {
        return priorityQueue.getTotalPriorityTxs();
    }

    function getSize() external view returns (uint256) {
        return priorityQueue.getSize();
    }

    function isEmpty() external view returns (bool) {
        return priorityQueue.isEmpty();
    }

    function pushBack(PriorityOperation memory _operation) external {
        return priorityQueue.pushBack(_operation);
    }

    function front() external view returns (PriorityOperation memory) {
        return priorityQueue.front();
    }

    function popFront() external returns (PriorityOperation memory operation) {
        return priorityQueue.popFront();
    }
}
