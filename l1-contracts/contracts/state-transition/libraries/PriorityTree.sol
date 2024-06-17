// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {DynamicIncrementalMerkle} from "../../common/libraries/openzeppelin/IncrementalMerkle.sol";
import {Merkle} from "./Merkle.sol";

struct PriorityOpsBatchInfo {
    bytes32[] leftPath;
    bytes32[] rightPath;
    bytes32[] itemHashes;
}

library PriorityTree {
    using PriorityTree for Tree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    struct Tree {
        uint256 startIndex;
        uint256 unprocessedIndex; // relative to `startIndex`
        mapping(bytes32 => bool) historicalRoots;
        DynamicIncrementalMerkle.Bytes32PushTree tree;
    }

    /// @notice Returns zero if and only if no operations were processed from the queue
    /// @return Index of the oldest priority operation that wasn't processed yet
    function getFirstUnprocessedPriorityTx(Tree storage _tree) internal view returns (uint256) {
        return _tree.startIndex + _tree.unprocessedIndex;
    }

    /// @return The total number of priority operations that were added to the priority queue, including all processed ones
    function getTotalPriorityTxs(Tree storage _tree) internal view returns (uint256) {
        return _tree.startIndex + _tree.tree._nextLeafIndex;
    }

    /// @return The total number of unprocessed priority operations in a priority queue
    function getSize(Tree storage _tree) internal view returns (uint256) {
        return uint256(_tree.tree._nextLeafIndex - _tree.unprocessedIndex);
    }

    /// @notice Add the priority operation to the end of the priority queue
    function push(Tree storage _tree, bytes32 _hash) internal {
        (, bytes32 newRoot) = _tree.tree.push(_hash);
        _tree.historicalRoots[newRoot] = true;
    }

    function setup(Tree storage _tree, bytes32 _zero, uint256 _startIndex) internal {
        _tree.tree.setup(_zero);
        _tree.startIndex = _startIndex;
    }

    function processBatch(
        Tree storage _tree,
        PriorityOpsBatchInfo calldata _priorityOpsData
    ) internal {
        bytes32 expectedRoot = Merkle.calculateRoot(
            _priorityOpsData.leftPath,
            _priorityOpsData.rightPath,
            _tree.unprocessedIndex,
            _priorityOpsData.itemHashes
        );
        require(_tree.historicalRoots[expectedRoot], "");
        _tree.unprocessedIndex += _priorityOpsData.itemHashes.length;
    }
}


