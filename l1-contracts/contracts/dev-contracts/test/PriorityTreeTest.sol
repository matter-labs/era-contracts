// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityTree, PriorityOpsBatchInfo, PriorityTreeCommitment} from "../../state-transition/libraries/PriorityTree.sol";

contract PriorityTreeTest {
    PriorityTree.Tree priorityTree;

    constructor() {
        PriorityTree.setup(priorityTree, 0);
    }

    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return PriorityTree.getFirstUnprocessedPriorityTx(priorityTree);
    }

    function getTotalPriorityTxs() external view returns (uint256) {
        return PriorityTree.getTotalPriorityTxs(priorityTree);
    }

    function getSize() external view returns (uint256) {
        return PriorityTree.getSize(priorityTree);
    }

    function push(bytes32 _hash) external {
        return PriorityTree.push(priorityTree, _hash);
    }

    function getRoot() external view returns (bytes32) {
        return PriorityTree.getRoot(priorityTree);
    }

    function processBatch(PriorityOpsBatchInfo calldata _priorityOpsData) external {
        PriorityTree.processBatch(priorityTree, _priorityOpsData);
    }

    function getCommitment() external view returns (PriorityTreeCommitment memory) {
        return PriorityTree.getCommitment(priorityTree);
    }

    function initFromCommitment(PriorityTreeCommitment calldata _commitment) external {
        PriorityTree.initFromCommitment(priorityTree, _commitment);
    }

    function getZero() external view returns (bytes32) {
        return priorityTree.tree._zeros[0];
    }
}
