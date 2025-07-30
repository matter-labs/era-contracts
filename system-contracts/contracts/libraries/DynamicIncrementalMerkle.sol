// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Merkle} from "./Merkle.sol";
import {Arrays} from "@openzeppelin/contracts-v4/utils/Arrays.sol";

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
library DynamicIncrementalMerkle {
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
        bool _needsRootRecalculation;
    }

    /**
     * @dev Initialize a {Bytes32PushTree} using {Hashes-Keccak256} to hash internal nodes.
     * The capacity of the tree (i.e. number of leaves) is set to `2**levels`.
     *
     * IMPORTANT: The zero value should be carefully chosen since it will be stored in the tree representing
     * empty leaves. It should be a value that is not expected to be part of the tree.
     */
    function setup(Bytes32PushTree storage self, bytes32 zero) internal returns (bytes32 initialRoot) {
        self._nextLeafIndex = 0;
        self._zeros.push(zero);
        self._sides.push(bytes32(0));
        return bytes32(0);
    }

    /// @dev Same as above, but for memory tree.
    function setupMemory(Bytes32PushTree memory self, bytes32 zero) internal pure returns (bytes32 initialRoot) {
        self._nextLeafIndex = 0;
        self._zeros[0] = zero;
        self._zerosLengthMemory = 1;
        self._sides[0] = bytes32(0);
        self._sidesLengthMemory = 1;
        return bytes32(0);
    }

    /**
     * @dev Resets the tree to a blank state.
     * Calling this function on MerkleTree that was already setup and used will reset it to a blank state.
     */
    function reset(Bytes32PushTree storage self, bytes32 zero) internal returns (bytes32 initialRoot) {
        clear(self);
        setup(self, zero);
    }

    function clear(Bytes32PushTree storage self) internal {
        self._nextLeafIndex = 0;
        uint256 length = self._zeros.length;
        for (uint256 i = length; 0 < i; --i) {
            self._zeros.pop();
        }
        length = self._sides.length;
        for (uint256 i = length; 0 < i; --i) {
            self._sides.pop();
        }
    }

    /// @dev Same as above, but for memory tree.
    function clearMemory(Bytes32PushTree memory self) internal pure {
        self._nextLeafIndex = 0;
        uint256 length = self._zerosLengthMemory;
        for (uint256 i = length; 0 < i; --i) {
            self._zeros[i] = bytes32(0);
        }
        length = self._sidesLengthMemory;
        for (uint256 i = length; 0 < i; --i) {
            self._sides[i] = bytes32(0);
        }
    }

    /**
     * @dev Internal function that handles both lazy and non-lazy push operations for storage.
     * Returns the index and optionally the new root (if not lazy).
     */
    function _pushInner(Bytes32PushTree storage self, bytes32 leaf, bool isLazy) internal returns (uint256 index, bytes32 newRoot) {
        // Cache read
        uint256 levels = self._zeros.length - 1;

        // Get leaf index
        // solhint-disable-next-line gas-increment-by-one
        index = self._nextLeafIndex++;

        // Check if tree is full.
        if (index == 1 << levels) {
            bytes32 zero = self._zeros[levels];
            bytes32 newZero = Merkle.efficientHash(zero, zero);
            self._zeros.push(newZero);
            self._sides.push(bytes32(0));
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
                Arrays.unsafeAccess(self._sides, i).value = currentLevelHash;
                updatedSides = true;
                if (isLazy) {
                    // Mark that root needs recalculation due to lazy update
                    self._needsRootRecalculation = true;
                    // Early return when sides are updated - we don't need to continue
                    return (index, bytes32(0));
                }
            }

            // Compute the current node hash by using the hash function
            // with either its sibling (side) or the zero value for that level.
            currentLevelHash = Merkle.efficientHash(
                isLeft ? currentLevelHash : Arrays.unsafeAccess(self._sides, i).value,
                isLeft ? Arrays.unsafeAccess(self._zeros, i).value : currentLevelHash
            );

            // Update node index
            currentIndex >>= 1;
        }

        Arrays.unsafeAccess(self._sides, levels).value = currentLevelHash;
        self._needsRootRecalculation = false;
        return (index, currentLevelHash);
    }

    /**
     * @dev Insert a new leaf in the tree lazily. Returns the position of the inserted leaf in the
     * tree. This is the lazy version that updates only the needed side array entry and defers
     * root computation until root() is called.
     *
     * Hashing the leaf before calling this function is recommended as a protection against
     * second pre-image attacks.
     */
    function pushLazy(Bytes32PushTree storage self, bytes32 leaf) internal returns (uint256 index) {
        (index, ) = _pushInner(self, leaf, true);
    }

    /**
     * @dev Insert a new leaf in the tree, and compute the new root. Returns the position of the inserted leaf in the
     * tree, and the resulting root.
     *
     * Hashing the leaf before calling this function is recommended as a protection against
     * second pre-image attacks.
     */
    function push(Bytes32PushTree storage self, bytes32 leaf) internal returns (uint256 index, bytes32 newRoot) {
        return _pushInner(self, leaf, false);
    }

    /**
     * @dev Internal function that handles both lazy and non-lazy push operations for memory.
     * Returns the index and optionally the new root (if not lazy).
     */
    function _pushInnerMemory(Bytes32PushTree memory self, bytes32 leaf, bool isLazy) internal pure returns (uint256 index, bytes32 newRoot) {
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
                updatedSides = true;
                if (isLazy) {
                    // Mark that root needs recalculation due to lazy update
                    self._needsRootRecalculation = true;
                    // Early return when sides are updated - we don't need to continue
                    return (index, bytes32(0));
                }
                // Note: in order to update the sides we should stop here. We continue in order to store the new root.
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
        self._needsRootRecalculation = false;
        return (index, currentLevelHash);
    }

    /// @dev Same as above, but for memory tree.
    function pushMemory(
        Bytes32PushTree memory self,
        bytes32 leaf
    ) internal pure returns (uint256 index, bytes32 newRoot) {
        return _pushInnerMemory(self, leaf, false);
    }

    /**
     * @dev Insert a new leaf in the memory tree lazily. Returns the position of the inserted leaf in the
     * tree. This is the lazy version that updates only the needed side array entry and defers
     * root computation until rootMemory() is called.
     *
     * Hashing the leaf before calling this function is recommended as a protection against
     * second pre-image attacks.
     */
    function pushLazyMemory(Bytes32PushTree memory self, bytes32 leaf) internal pure returns (uint256 index) {
        (index, ) = _pushInnerMemory(self, leaf, true);
    }

    /**
     * @dev Extend until end.
     */
    function extendUntilEnd(Bytes32PushTree storage self, uint256 finalDepth) internal {
        bytes32 currentZero = self._zeros[self._zeros.length - 1];
        if (self._nextLeafIndex == 0) {
            self._sides[0] = currentZero;
        }
        bytes32 currentSide = self._sides[self._sides.length - 1];
        for (uint256 i = self._sides.length; i < finalDepth; ++i) {
            currentSide = Merkle.efficientHash(currentSide, currentZero);
            currentZero = Merkle.efficientHash(currentZero, currentZero);
            // at i
            self._zeros.push(currentZero);
            self._sides.push(currentSide);
        }
    }

    /// @dev Same as above, but for memory tree.
    function extendUntilEndMemory(Bytes32PushTree memory self) internal pure {
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
     * @dev Recalculate the root from current tree state when lazy updates have been made.
     */
    function _recalculateRoot(Bytes32PushTree storage self) internal view returns (bytes32) {
        uint256 levels = self._zeros.length - 1;
        uint256 leafCount = self._nextLeafIndex;

        if (leafCount == 0) {
            return bytes32(0);
        }

        uint256 currentIndex = leafCount - 1;

        bytes32 currentLevelHash = Arrays.unsafeAccess(self._sides, 0).value;

        for (uint32 i = 0; i < levels; ++i) {
            bool isLeft = (currentIndex % 2) == 0;

            currentLevelHash = Merkle.efficientHash(
                isLeft ? currentLevelHash : Arrays.unsafeAccess(self._sides, i).value,
                isLeft ? Arrays.unsafeAccess(self._zeros, i).value : currentLevelHash
            );

            currentIndex >>= 1;
        }

        return currentLevelHash;
    }

    /**
     * @dev Tree's root.
     */
    function root(Bytes32PushTree storage self) internal returns (bytes32) {
        if (self._needsRootRecalculation) {
            bytes32 newRoot = _recalculateRoot(self);
            Arrays.unsafeAccess(self._sides, self._sides.length - 1).value = newRoot;
            self._needsRootRecalculation = false;
            return newRoot;
        }
        return Arrays.unsafeAccess(self._sides, self._sides.length - 1).value;
    }

    /**
     * @dev Recalculate the root from current tree state when lazy updates have been made.
     * This simulates what a complete pushes sequence would have computed.
     */
    function _recalculateRootMemory(Bytes32PushTree memory self) internal pure returns (bytes32) {
        uint256 levels = self._zerosLengthMemory - 1;
        uint256 leafCount = self._nextLeafIndex;

        if (leafCount == 0) {
            return bytes32(0);
        }

        uint256 currentIndex = leafCount - 1;

        bytes32 currentLevelHash = bytes32(leafCount - 1);

        for (uint32 i = 0; i < levels; ++i) {
            bool isLeft = (currentIndex % 2) == 0;

            currentLevelHash = Merkle.efficientHash(
                isLeft ? currentLevelHash : self._sides[i],
                isLeft ? self._zeros[i] : currentLevelHash
            );

            currentIndex >>= 1;
        }

        return currentLevelHash;
    }

    /// @dev Same as above, but for memory tree.
    function rootMemory(Bytes32PushTree memory self) internal pure returns (bytes32) {
        if (self._needsRootRecalculation) {
            bytes32 newRoot = _recalculateRootMemory(self);
            self._sides[self._sidesLengthMemory - 1] = newRoot;
            self._needsRootRecalculation = false;
            return newRoot;
        }
        return self._sides[self._sidesLengthMemory - 1];
    }

    /**
     * @dev Tree's height (does not include the root node).
     */
    function height(Bytes32PushTree storage self) internal view returns (uint256) {
        return self._sides.length - 1;
    }

    /// @dev Same as above, but for memory tree.
    function heightMemory(Bytes32PushTree memory self) internal pure returns (uint256) {
        return self._sidesLengthMemory - 1;
    }
}
