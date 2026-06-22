// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MAX_LOW_INDEX_SEARCH_ATTEMPTS} from "../Config.sol";
import {
    IMTAlreadyInitialized,
    IMTCapacityExceeded,
    IMTLowLeafIndexOutOfBounds,
    IMTLowLeafNextTooSmall,
    IMTLowLeafValueTooLarge,
    IMTLeafValueMismatch,
    IMTNotInitialized,
    IMTValueAlreadyExists,
    IMTValueZero
} from "../L1ContractErrors.sol";
import {FullMerkle} from "./FullMerkle.sol";
import {Merkle} from "./Merkle.sol";

/// @dev A leaf preimage in the indexed Merkle tree.
/// `value`, `nextIndex`, and `nextValue` form a sorted singly linked list across all leaves.
struct IMTLeaf {
    uint256 value;
    uint256 nextIndex;
    uint256 nextValue;
}

/// @dev Storage layout for an indexed Merkle tree.
/// `tree` stores hashes of the leaf preimages using {FullMerkle}. `leaves[i]` stores full leaf
/// preimages needed for sorted-list updates. `valueToIndex[v]` rejects duplicate values.
struct IMT {
    FullMerkle.FullTree tree;
    mapping(uint256 leafIndex => IMTLeaf leaf) leaves;
    mapping(uint256 value => uint256 leafIndex) valueToIndex;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library IndexedMerkleTree {
    using FullMerkle for FullMerkle.FullTree;

    /// @notice Initialize an {IMT} and reserve index 0 for the sentinel zero leaf.
    function setup(IMT storage self) internal {
        if (self.tree._leafNumber != 0) {
            revert IMTAlreadyInitialized();
        }

        bytes32 zeroLeafHash = hashLeaf(IMTLeaf({value: 0, nextIndex: 0, nextValue: 0}));
        self.tree.setup(zeroLeafHash);
        self.tree.pushNewLeaf(zeroLeafHash);
        self.leaves[0] = IMTLeaf({value: 0, nextIndex: 0, nextValue: 0});
    }

    /// @notice Insert a new value in the tree.
    /// @param _value The value to be inserted.
    /// @param _lowLeafIndex The index of a leaf expected to precede `_value`.
    /// @dev If `_lowLeafIndex` is incorrect, the function will attempt to find the correct low leaf by traversing the linked list
    /// up to `MAX_LOW_INDEX_SEARCH_ATTEMPTS` times.
    /// @return newIndex The index of the inserted leaf.
    /// @return newRoot The root after insertion.
    function insert(IMT storage self, uint256 _value, uint256 _lowLeafIndex)
        internal
        returns (uint256 newIndex, bytes32 newRoot)
    {
        uint256 leafNumber = self.tree._leafNumber;
        if (leafNumber == 0) {
            revert IMTNotInitialized();
        }
        if (_value == 0) {
            revert IMTValueZero();
        }
        if (self.valueToIndex[_value] != 0) {
            revert IMTValueAlreadyExists(_value);
        }
        if (_lowLeafIndex >= leafNumber) {
            revert IMTLowLeafIndexOutOfBounds(_lowLeafIndex, leafNumber);
        }

        uint256 lowLeafIndex = _lowLeafIndex;
        IMTLeaf memory lowLeaf = self.leaves[lowLeafIndex];
        if (lowLeaf.value >= _value) {
            revert IMTLowLeafValueTooLarge(lowLeaf.value, _value);
        }

        for (uint256 attempts = 0; lowLeaf.nextValue != 0 && lowLeaf.nextValue < _value; ++attempts) {
            if (attempts == MAX_LOW_INDEX_SEARCH_ATTEMPTS) {
                revert IMTLowLeafNextTooSmall(lowLeaf.nextValue, _value);
            }

            lowLeafIndex = lowLeaf.nextIndex;
            lowLeaf = self.leaves[lowLeafIndex];
        }

        newIndex = leafNumber;s

        uint256 oldNextIndex = lowLeaf.nextIndex;
        uint256 oldNextValue = lowLeaf.nextValue;
        IMTLeaf memory updatedLowLeaf = IMTLeaf({value: lowLeaf.value, nextIndex: newIndex, nextValue: _value});
        self.leaves[lowLeafIndex] = updatedLowLeaf;
        self.tree.updateLeaf(lowLeafIndex, hashLeaf(updatedLowLeaf));

        IMTLeaf memory newLeaf = IMTLeaf({value: _value, nextIndex: oldNextIndex, nextValue: oldNextValue});
        self.leaves[newIndex] = newLeaf;
        self.valueToIndex[_value] = newIndex;
        newRoot = self.tree.pushNewLeaf(hashLeaf(newLeaf));
    }

    /// @dev Returns the current Merkle root.
    function root(IMT storage self) internal view returns (bytes32) {
        return self.tree.root();
    }

    /// @dev Returns a Merkle path for a leaf using the current {FullMerkle} height.
    /// @param _leafIndex The index of the leaf to calculate proof for.
    function merklePath(IMT storage self, uint256 _leafIndex) internal view returns (bytes32[] memory path) {
        path = self.tree.merklePath(_leafIndex);
    }

    /// @dev Hashes a leaf in the canonical indexed Merkle tree layout.
    /// @param _leaf The leaf preimage to hash.
    function hashLeaf(IMTLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextIndex, _leaf.nextValue));
    }

    /// @dev Verifies that `_value` is present in a tree with root `_root`.
    /// @param _root The root to verify against.
    /// @param _value The value expected to be present.
    /// @param _leaf The leaf preimage for `_value`.
    /// @param _leafIndex The index of `_leaf`.
    /// @param _proof The Merkle path from `_leaf` to `_root`.
    function verifyInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _leaf,
        uint256 _leafIndex,
        bytes32[] memory _proof
    ) internal pure returns (bool) {
        if (_leaf.value != _value) {
            revert IMTLeafValueMismatch(_value, _leaf.value);
        }

        return Merkle.calculateRootMemory(_proof, _leafIndex, hashLeaf(_leaf)) == _root;
    }

    /// @dev Verifies that `_value` is absent from a tree with root `_root` by proving its low leaf.
    /// @param _root The root to verify against.
    /// @param _value The value expected to be absent.
    /// @param _lowLeaf The leaf preimage that precedes `_value` in the sorted linked list.
    /// @param _lowLeafIndex The index of `_lowLeaf`.
    /// @param _lowLeafProof The Merkle path from `_lowLeaf` to `_root`.
    function verifyNonInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] memory _lowLeafProof
    ) internal pure returns (bool) {
        if (_value == 0) {
            revert IMTValueZero();
        }
        if (_lowLeaf.value >= _value) {
            revert IMTLowLeafValueTooLarge(_lowLeaf.value, _value);
        }
        if (_lowLeaf.nextValue != 0 && _lowLeaf.nextValue <= _value) {
            revert IMTLowLeafNextTooSmall(_lowLeaf.nextValue, _value);
        }

        return Merkle.calculateRootMemory(_lowLeafProof, _lowLeafIndex, hashLeaf(_lowLeaf)) == _root;
    }
}
