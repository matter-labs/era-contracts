// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Merkle} from "./Merkle.sol";

/**
 * @dev Library for managing https://wikipedia.org/wiki/Merkle_Tree[Merkle Tree] data structures.
 *
 * Each tree is a complete binary tree with the ability to sequentially insert leaves, changing them from a zero to a
 * non-zero value and updating its root. This structure allows inserting commitments (or other entries) that are not
 * stored, but can be proven to be part of the tree at a later time if the root is kept. See {MerkleProof}.
 *
 * A tree is defined by the following parameters:
 *
 * * Depth: The number of levels in the tree, it also defines the maximum number of leaves as 2**depth.
 * * Zero value: The value that represents an empty leaf. Used to avoid regular zero values to be part of the tree.
 * * Hashing function: A cryptographic hash function used to produce internal nodes.
 *
 * This is a fork of OpenZeppelin's [`MerkleTree`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/9af280dc4b45ee5bda96ba47ff829b407eaab67e/contracts/utils/structs/MerkleTree.sol)
 * library, with the changes to support dynamic tree growth (doubling the size when full).
 */
library DynamicIncrementalMerkleMemory {
    /**
     * @dev A complete `bytes32` Merkle tree.
     *
     * The `sides` and `zero` arrays are set to have a length equal to the depth of the tree during setup.
     *
     * Struct members have an underscore prefix indicating that they are "private" and should not be read or written to
     * directly. Use the functions provided below instead. Modifying the struct manually may violate assumptions and
     * lead to unexpected behavior.
     *
     * NOTE: The `root` and the updates history is not stored within the tree. Consider using a secondary structure to
     * store a list of historical roots from the values returned from {setup} and {push} (e.g. a mapping, {BitMaps} or
     * {Checkpoints}).
     *
     * WARNING: Updating any of the tree's parameters after the first insertion will result in a corrupted tree.
     */
    struct Bytes32PushTree {
        uint256 _nextLeafIndex;
        bytes32[] _sides;
        bytes32[] _zeros;
        uint256 _sidesLengthMemory;
        uint256 _zerosLengthMemory;
        bytes32[] _pendingLeaves;
        uint256 _pendingLeavesLengthMemory;
    }

    /**
     * @dev Initialize a {Bytes32PushTree} using {Hashes-Keccak256} to hash internal nodes.
     * The capacity of the tree (i.e. number of leaves) is set to `2**levels`.
     *
     * IMPORTANT: The zero value should be carefully chosen since it will be stored in the tree representing
     * empty leaves. It should be a value that is not expected to be part of the tree.
     */
    function setup(Bytes32PushTree memory self, bytes32 zero) internal pure returns (bytes32 initialRoot) {
        self._nextLeafIndex = 0;
        self._zeros[0] = zero;
        self._zerosLengthMemory = 1;
        self._sides[0] = bytes32(0);
        self._sidesLengthMemory = 1;
        return bytes32(0);
    }

    /**
     * @dev Insert a new leaf in the tree, and compute the new root. Returns the position of the inserted leaf in the
     * tree, and the resulting root.
     *
     * Hashing the leaf before calling this function is recommended as a protection against
     * second pre-image attacks.
     */
    function push(Bytes32PushTree memory self, bytes32 leaf) internal returns (uint256 index, bytes32 newRoot) {
        if (self._pendingLeavesLengthMemory > 0) {
            recalculateRoot(self);
        }
        // Cache read
        uint256 levels = self._zerosLengthMemory - 1;

        // Get leaf index
        // solhint-disable-next-line gas-increment-by-one
        index = self._nextLeafIndex++;

        // Check if tree is full.
        if (index == 1 << levels) {
            bytes32 zero = self._zeros[levels];
            bytes32 newZero = Merkle.efficientHash(zero, zero);
            self._zeros[self._zerosLengthMemory] = newZero;
            ++self._zerosLengthMemory;
            self._sides[self._sidesLengthMemory] = bytes32(0);
            ++self._sidesLengthMemory;
            ++levels;
        }

        // Rebuild branch from leaf to root
        uint256 currentIndex = index;
        bytes32 currentLevelHash = leaf;
        bool updatedSides = false;
        for (uint32 i = 0; i < levels; ++i) {
            // Reaching the parent node, is currentLevelHash the left child?
            bool isLeft = currentIndex % 2 == 0;

            // If so, next time we will come from the right, so we need to save it
            if (isLeft && !updatedSides) {
                self._sides[i] = currentLevelHash;
                // Note: in order to update the sides we should stop here. We continue in order to store the new root.
                updatedSides = true;
            }

            // Compute the current node hash by using the hash function
            // with either its sibling (side) or the zero value for that level.
            currentLevelHash = Merkle.efficientHash(
                isLeft ? currentLevelHash : self._sides[i],
                isLeft ? self._zeros[i] : currentLevelHash
            );

            // Update node index
            currentIndex >>= 1;
        }
        // Note this is overloading the sides array with the root.
        self._sides[levels] = currentLevelHash;
        return (index, currentLevelHash);
    }

    /**
     * @dev Insert a new leaf in the memory tree without recalculating the root, deferring computation for batch processing.
     * This is the memory version of pushLazy() with the same efficiency benefits.
     */
    function pushLazy(Bytes32PushTree memory self, bytes32 leaf) internal pure returns (uint256 index) {
        index = self._nextLeafIndex + self._pendingLeavesLengthMemory;
        self._pendingLeaves[self._pendingLeavesLengthMemory] = leaf;
        ++self._pendingLeavesLengthMemory;
        return index;
    }

    /**
     * @dev Process all pending leaves and recalculate the tree root using optimized batch processing for memory trees.
     * This is the memory version of recalculateRoot() with the same O(pendingLeaves + log² n) complexity.
     */
    function recalculateRoot(Bytes32PushTree memory self) internal pure returns (bytes32 newRoot) {
        uint256 pendingCount = self._pendingLeavesLengthMemory;
        if (pendingCount == 0) {
            return self._sides[self._sidesLengthMemory - 1];
        }

        uint256 startIndex = self._nextLeafIndex;

        // Extend tree if needed to accommodate all pending leaves
        uint256 levels = self._zerosLengthMemory - 1;
        while (startIndex + pendingCount > (1 << levels)) {
            bytes32 zero = self._zeros[levels];
            bytes32 newZero = Merkle.efficientHash(zero, zero);
            self._zeros[self._zerosLengthMemory] = newZero;
            ++self._zerosLengthMemory;
            self._sides[self._sidesLengthMemory] = bytes32(0);
            ++self._sidesLengthMemory;
            ++levels;
        }

        // Process leaves in optimally-sized batches that align with tree structure
        uint256 processed = 0;
        while (processed < pendingCount) {
            // Find the largest power-of-2 batch that starts at an even boundary
            uint256 currentIndex = startIndex + processed;
            uint256 remaining = pendingCount - processed;

            // Find the largest batch size that:
            // 1. Is a power of 2 (aligns with binary tree structure)
            // 2. Doesn't exceed remaining leaves
            // 3. Starts at even boundary for its level (minimizes tree updates)
            uint256 batchSize = 1;
            while (batchSize * 2 <= remaining && (currentIndex % (batchSize * 2)) == 0) {
                batchSize *= 2;
            }

            // Build complete subtree for this batch - O(batchSize) complexity
            bytes32[] memory currentLevel = new bytes32[](batchSize);
            for (uint256 i = 0; i < batchSize; ++i) {
                currentLevel[i] = self._pendingLeaves[processed + i];
            }

            // Hash up the subtree bottom-up until we have a single root
            uint256 subtreeHeight = 0;
            uint256 currentLevelLength = currentLevel.length;
            while (currentLevelLength > 1) {
                uint256 nextLevelSize = currentLevelLength / 2;
                bytes32[] memory nextLevel = new bytes32[](nextLevelSize);

                for (uint256 i = 0; i < nextLevelSize; ++i) {
                    nextLevel[i] = Merkle.efficientHash(currentLevel[i * 2], currentLevel[i * 2 + 1]);
                }

                currentLevel = nextLevel;
                currentLevelLength = nextLevelSize;
                ++subtreeHeight;
            }

            bytes32 subtreeRoot = currentLevel[0];

            // Integrate subtree root into main tree - O(log n) complexity
            // Separate helper function to avoid stack too deep.
            subtreeRoot = _integrateSubtreeRoot({
                self: self,
                subtreeRoot: subtreeRoot,
                currentIndex: currentIndex,
                subtreeHeight: subtreeHeight,
                levels: levels
            });

            processed += batchSize;
            newRoot = subtreeRoot;
        }

        // Update tree state and clean up
        self._nextLeafIndex += pendingCount;
        self._sides[levels] = newRoot;

        // Clear pending leaves in memory
        for (uint256 i = 0; i < self._pendingLeavesLengthMemory; ++i) {
            self._pendingLeaves[i] = bytes32(0);
        }
        self._pendingLeavesLengthMemory = 0;

        return newRoot;
    }

    /**
     * @dev Extend until end.
     */
    /// @dev here we can extend the array, so the depth is not predetermined.
    function extendUntilEnd(Bytes32PushTree memory self) internal pure {
        bytes32 currentZero = self._zeros[self._zerosLengthMemory - 1];
        if (self._nextLeafIndex == 0) {
            self._sides[0] = currentZero;
        }
        bytes32 currentSide = self._sides[self._sidesLengthMemory - 1];
        uint256 finalDepth = self._sides.length;
        for (uint256 i = self._sidesLengthMemory; i < finalDepth; ++i) {
            currentSide = Merkle.efficientHash(currentSide, currentZero);
            currentZero = Merkle.efficientHash(currentZero, currentZero);
            self._zeros[i] = currentZero;
            self._sides[i] = currentSide;
        }
        self._sidesLengthMemory = self._sides.length;
        self._zerosLengthMemory = self._zeros.length;
    }

    /**
     * @dev Tree's root.
     */
    function root(Bytes32PushTree memory self) internal pure returns (bytes32) {
        if (self._pendingLeavesLengthMemory > 0) {
            return recalculateRoot(self);
        }
        // note the last element of the sides array is the root, and is not really a side.
        return self._sides[self._sidesLengthMemory - 1];
    }

    /**
     * @dev Tree's height (does not include the root node).
     */
    function height(Bytes32PushTree memory self) internal pure returns (uint256) {
        return self._sidesLengthMemory - 1;
    }

    /**
     * @dev Internal helper to integrate subtree root into main tree
     */
    function _integrateSubtreeRoot(
        Bytes32PushTree memory self,
        bytes32 subtreeRoot,
        uint256 currentIndex,
        uint256 subtreeHeight,
        uint256 levels
    ) internal pure returns (bytes32) {
        uint256 pos = currentIndex >> subtreeHeight;
        for (uint256 level = subtreeHeight; level < levels; ++level) {
            bool isLeft = (pos % 2) == 0;

            // Update sides array if this is a left child
            if (isLeft) {
                self._sides[level] = subtreeRoot;
            }

            // Calculate parent hash using sibling from sides or zero
            subtreeRoot = Merkle.efficientHash(
                isLeft ? subtreeRoot : self._sides[level],
                isLeft ? self._zeros[level] : subtreeRoot
            );

            pos >>= 1;
        }
        return subtreeRoot;
    }
}
