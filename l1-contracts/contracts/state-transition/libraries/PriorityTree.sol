// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {DynamicIncrementalMerkle} from "../../common/libraries/DynamicIncrementalMerkle.sol";
import {Merkle} from "../../common/libraries/Merkle.sol";
import {PriorityTreeCommitment} from "../../common/Config.sol";
import {RootMismatch, InvalidCommitment, InvalidStartIndex, InvalidUnprocessedIndex, InvalidNextLeafIndex} from "../L1StateTransitionErrors.sol";

struct PriorityOpsBatchInfo {
    bytes32[] leftPath;
    bytes32[] rightPath;
    bytes32[] itemHashes;
}

bytes32 constant ZERO_LEAF_HASH = keccak256("");

library PriorityTree {
    using PriorityTree for Tree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    struct Tree {
        uint256 startIndex; // priority tree started accepting priority ops from this index
        uint256 unprocessedIndex; // relative to `startIndex`
        mapping(bytes32 => bool) historicalRoots;
        DynamicIncrementalMerkle.Bytes32PushTree tree;
    }

    /// @notice Returns zero if and only if no operations were processed from the tree
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
        return _tree.tree._nextLeafIndex - _tree.unprocessedIndex;
    }

    /// @notice Add the priority operation to the end of the priority queue
    function push(Tree storage _tree, bytes32 _hash) internal {
        (, bytes32 newRoot) = _tree.tree.push(_hash);
        _tree.historicalRoots[newRoot] = true;
    }

    /// @notice Set up the tree
    function setup(Tree storage _tree, uint256 _startIndex) internal {
        _tree.tree.setup(ZERO_LEAF_HASH);
        _tree.startIndex = _startIndex;
    }

    /// @return Returns the tree root.
    function getRoot(Tree storage _tree) internal view returns (bytes32) {
        return _tree.tree.root();
    }

    /// @param _root The root to check.
    /// @return Returns true if the root is a historical root.
    function isHistoricalRoot(Tree storage _tree, bytes32 _root) internal view returns (bool) {
        return _tree.historicalRoots[_root];
    }

    /// @notice Process the priority operations of a batch.
    function processBatch(Tree storage _tree, PriorityOpsBatchInfo memory _priorityOpsData) internal {
        if (_priorityOpsData.itemHashes.length > 0) {
            bytes32 expectedRoot = Merkle.calculateRootPaths(
                _priorityOpsData.leftPath,
                _priorityOpsData.rightPath,
                _tree.unprocessedIndex,
                _priorityOpsData.itemHashes
            );
            if (!_tree.historicalRoots[expectedRoot]) {
                revert RootMismatch();
            }
            _tree.unprocessedIndex += _priorityOpsData.itemHashes.length;
        }
    }

    /// @notice Initialize a chain from a commitment.
    function initFromCommitment(Tree storage _tree, PriorityTreeCommitment memory _commitment) internal {
        uint256 height = _commitment.sides.length; // Height, including the root node.
        if (height == 0) {
            revert InvalidCommitment();
        }
        _tree.startIndex = _commitment.startIndex;
        _tree.unprocessedIndex = _commitment.unprocessedIndex;
        _tree.tree._nextLeafIndex = _commitment.nextLeafIndex;
        _tree.tree._sides = _commitment.sides;
        bytes32 zero = ZERO_LEAF_HASH;
        _tree.tree._zeros = new bytes32[](height);
        for (uint256 i; i < height; ++i) {
            _tree.tree._zeros[i] = zero;
            zero = Merkle.efficientHash(zero, zero);
        }
        _tree.historicalRoots[_tree.tree.root()] = true;
    }

    /// @notice Reinitialize the tree from a commitment on L1.
    function l1Reinit(Tree storage _tree, PriorityTreeCommitment memory _commitment) internal {
        if (_tree.startIndex != _commitment.startIndex) {
            revert InvalidStartIndex(_tree.startIndex, _commitment.startIndex);
        }
        if (_tree.unprocessedIndex > _commitment.unprocessedIndex) {
            revert InvalidUnprocessedIndex(_tree.unprocessedIndex, _commitment.unprocessedIndex);
        }
        if (_tree.tree._nextLeafIndex < _commitment.nextLeafIndex) {
            revert InvalidNextLeafIndex(_tree.tree._nextLeafIndex, _commitment.nextLeafIndex);
        }

        _tree.unprocessedIndex = _commitment.unprocessedIndex;
    }

    /// @notice Reinitialize the tree from a commitment on GW.
    function checkGWReinit(Tree storage _tree, PriorityTreeCommitment memory _commitment) internal view {
        if (_tree.startIndex != _commitment.startIndex) {
            revert InvalidStartIndex(_tree.startIndex, _commitment.startIndex);
        }
        if (_tree.unprocessedIndex > _commitment.unprocessedIndex) {
            revert InvalidUnprocessedIndex(_tree.unprocessedIndex, _commitment.unprocessedIndex);
        }
        if (_tree.tree._nextLeafIndex > _commitment.nextLeafIndex) {
            revert InvalidNextLeafIndex(_tree.tree._nextLeafIndex, _commitment.nextLeafIndex);
        }
    }

    /// @notice Returns the commitment to the priority tree.
    function getCommitment(Tree storage _tree) internal view returns (PriorityTreeCommitment memory commitment) {
        commitment.nextLeafIndex = _tree.tree._nextLeafIndex;
        commitment.startIndex = _tree.startIndex;
        commitment.unprocessedIndex = _tree.unprocessedIndex;
        commitment.sides = _tree.tree._sides;
    }
}
