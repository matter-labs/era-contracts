// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

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

    /**
     * @dev Resets the tree to a blank state.
     * Calling this function on MerkleTree that was already setup and used will reset it to a blank state.
     * @param zero The value that represents an empty leaf.
     * @return initialRoot The initial root of the tree.
     */
    function reset(Bytes32PushTree storage self, bytes32 zero) internal returns (bytes32 initialRoot) {
        self._nextLeafIndex = 0;
        uint256 length = self._zeros.length;
        for (uint256 i = length; 0 < i; --i) {
            self._zeros.pop();
        }
        length = self._sides.length;
        for (uint256 i = length; 0 < i; --i) {
            self._sides.pop();
        }
        self._zeros.push(zero);
        self._sides.push(bytes32(0));
        return bytes32(0);
    }

    /**
     * @dev Insert a new leaf in the tree, and compute the new root. Returns the position of the inserted leaf in the
     * tree, and the resulting root.
     *
     * Hashing the leaf before calling this function is recommended as a protection against
     * second pre-image attacks.
     */
    function push(Bytes32PushTree storage self, bytes32 leaf) internal returns (uint256 index, bytes32 newRoot) {
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
        return (index, currentLevelHash);
    }

    /**
     * @dev Tree's root.
     */
    function root(Bytes32PushTree storage self) internal view returns (bytes32) {
        return Arrays.unsafeAccess(self._sides, self._sides.length - 1).value;
    }

    /**
     * @dev Tree's height (does not include the root node).
     */
    function height(Bytes32PushTree storage self) internal view returns (uint256) {
        return self._sides.length - 1;
    }
}
