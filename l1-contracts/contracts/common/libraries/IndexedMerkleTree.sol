// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Merkle} from "./Merkle.sol";
import {
    IMTAlreadyInitialized,
    IMTCapacityExceeded,
    IMTLowLeafIndexOutOfBounds,
    IMTLowLeafNextTooSmall,
    IMTLowLeafValueTooLarge,
    IMTNotInitialized,
    IMTProofWrongLength,
    IMTValueAlreadyExists,
    IMTValueZero
} from "../L1ContractErrors.sol";

/// @dev Fixed depth of the Indexed Merkle Tree. 2^32 ≈ 4.29B leaves — practically unbounded for
/// recording per-flow finality facts.
uint256 constant IMT_DEPTH = 32;

/// @dev `value`, `nextIndex`, `nextValue` form a sorted singly-linked list across all leaves,
/// starting from the sentinel zero leaf at index 0 (`{0, 0, 0}` initially, with `nextIndex` /
/// `nextValue` updated as larger values are inserted). The list lets us prove non-inclusion by
/// exhibiting the leaf whose interval `(value, nextValue)` brackets the queried value.
struct IMTLeaf {
    uint256 value;
    uint256 nextIndex;
    uint256 nextValue;
}

/// @dev Storage layout for an Indexed Merkle Tree.
///
/// `zeros[i]` is the hash of an entirely empty subtree of height `i`. `zeros[0]` is the hash of
/// the empty `IMTLeaf{0,0,0}`. We materialize them once at setup and use them as default siblings
/// when reading from `nodes[level][index]` returns the unwritten sentinel `bytes32(0)`.
///
/// `nodes[level][index]` stores written merkle nodes. Level 0 is the leaf level; level
/// `IMT_DEPTH` holds the single root at index 0.
///
/// `leaves[i]` and `valueToIndex[v]` exist purely for on-chain insert logic (to look up the low
/// leaf and to reject duplicate insertions). Verification is fully content-addressed via merkle
/// proofs and never reads these.
struct IMT {
    bytes32[IMT_DEPTH + 1] zeros;
    mapping(uint256 level => mapping(uint256 index => bytes32 nodeHash)) nodes;
    mapping(uint256 leafIndex => IMTLeaf leaf) leaves;
    mapping(uint256 value => uint256 leafIndex) valueToIndex;
    uint256 leafCount;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Fixed-depth Indexed Merkle Tree. Supports insertion of distinct non-zero values plus
/// content-addressed inclusion / non-inclusion verification against any historical root snapshot.
///
/// Used by the atomicity Simulator to record finalized flowIds: the source chain inserts a fact,
/// other chains verify inclusion to finalize their leg, or non-inclusion (after timeout) to revert.
library IndexedMerkleTreeLib {
    /// @notice Initialize the tree. Must be called exactly once before any insert.
    /// @dev Pre-computes `zeros[]` and reserves index 0 for the sentinel `{0, 0, 0}` leaf so that
    /// every later insert always finds a valid low leaf.
    function setup(IMT storage self) internal {
        if (self.leafCount != 0) revert IMTAlreadyInitialized();

        bytes32 zeroLeafHash = hashLeaf(IMTLeaf({value: 0, nextIndex: 0, nextValue: 0}));
        self.zeros[0] = zeroLeafHash;
        for (uint256 i = 0; i < IMT_DEPTH; ++i) {
            self.zeros[i + 1] = Merkle.efficientHash(self.zeros[i], self.zeros[i]);
        }

        // Materialize the sentinel zero leaf at index 0. The full path is also the all-zeros
        // path, so writing nodes[0][0] is enough — every parent is implicitly `zeros[level]`.
        self.nodes[0][0] = zeroLeafHash;
        self.leaves[0] = IMTLeaf({value: 0, nextIndex: 0, nextValue: 0});
        self.leafCount = 1;
    }

    /// @notice Insert a new value into the tree. Caller supplies the index of the low leaf
    /// (predecessor in the sorted linked list); we validate it brackets `_value`.
    function insert(
        IMT storage self,
        uint256 _value,
        uint256 _lowLeafIndex
    ) internal returns (uint256 newIndex, bytes32 newRoot) {
        if (self.leafCount == 0) revert IMTNotInitialized();
        if (_value == 0) revert IMTValueZero();
        if (self.valueToIndex[_value] != 0) revert IMTValueAlreadyExists(_value);
        if (_lowLeafIndex >= self.leafCount) revert IMTLowLeafIndexOutOfBounds(_lowLeafIndex, self.leafCount);

        IMTLeaf memory low = self.leaves[_lowLeafIndex];
        if (low.value >= _value) revert IMTLowLeafValueTooLarge(low.value, _value);
        // `nextValue == 0` means low is the current tail; otherwise it must strictly bracket `_value`.
        if (low.nextValue != 0 && low.nextValue <= _value) revert IMTLowLeafNextTooSmall(low.nextValue, _value);

        newIndex = self.leafCount;
        if (newIndex >= (1 << IMT_DEPTH)) revert IMTCapacityExceeded();
        self.leafCount = newIndex + 1;

        // Splice the new leaf into the linked list: low → new → low.next.
        uint256 oldNextIndex = low.nextIndex;
        uint256 oldNextValue = low.nextValue;
        IMTLeaf memory updatedLow = IMTLeaf({value: low.value, nextIndex: newIndex, nextValue: _value});
        self.leaves[_lowLeafIndex] = updatedLow;
        _updatePath(self, _lowLeafIndex, hashLeaf(updatedLow));

        IMTLeaf memory newLeaf = IMTLeaf({value: _value, nextIndex: oldNextIndex, nextValue: oldNextValue});
        self.leaves[newIndex] = newLeaf;
        self.valueToIndex[_value] = newIndex;
        newRoot = _updatePath(self, newIndex, hashLeaf(newLeaf));
    }

    /// @notice Current merkle root.
    function root(IMT storage self) internal view returns (bytes32) {
        bytes32 r = self.nodes[IMT_DEPTH][0];
        return r == bytes32(0) ? self.zeros[IMT_DEPTH] : r;
    }

    /// @notice Build a merkle path for a leaf, suitable for off-chain proof construction.
    function merklePath(IMT storage self, uint256 _leafIndex) internal view returns (bytes32[] memory path) {
        path = new bytes32[](IMT_DEPTH);
        uint256 idx = _leafIndex;
        for (uint256 level = 0; level < IMT_DEPTH; ++level) {
            uint256 siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1;
            path[level] = _siblingAt(self, level, siblingIdx);
            idx /= 2;
        }
    }

    /// @notice Hash of a leaf in canonical IMT layout.
    function hashLeaf(IMTLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextIndex, _leaf.nextValue));
    }

    /// @notice Verify that `_value` is present in a tree with root `_root`. Pure / cross-chain safe.
    function verifyInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _leaf,
        uint256 _leafIndex,
        bytes32[] memory _proof
    ) internal pure returns (bool) {
        if (_proof.length != IMT_DEPTH) revert IMTProofWrongLength(IMT_DEPTH, _proof.length);
        if (_leaf.value != _value) return false;
        return Merkle.calculateRootMemory(_proof, _leafIndex, hashLeaf(_leaf)) == _root;
    }

    /// @notice Verify that `_value` is NOT in a tree with root `_root`, by exhibiting the low leaf
    /// whose interval `(value, nextValue)` brackets it.
    function verifyNonInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] memory _lowLeafProof
    ) internal pure returns (bool) {
        if (_lowLeafProof.length != IMT_DEPTH) revert IMTProofWrongLength(IMT_DEPTH, _lowLeafProof.length);
        if (_value == 0) return false; // index 0 is always present as the sentinel zero leaf.
        if (_lowLeaf.value >= _value) return false;
        // `nextValue == 0` means low is the tail and bounds everything above it.
        if (_lowLeaf.nextValue != 0 && _lowLeaf.nextValue <= _value) return false;
        return Merkle.calculateRootMemory(_lowLeafProof, _lowLeafIndex, hashLeaf(_lowLeaf)) == _root;
    }

    /// @dev Recompute the path from a single leaf up to the root, writing every node on the way.
    function _updatePath(IMT storage self, uint256 _leafIndex, bytes32 _leafHash) private returns (bytes32) {
        self.nodes[0][_leafIndex] = _leafHash;
        bytes32 currentHash = _leafHash;
        uint256 idx = _leafIndex;
        for (uint256 level = 0; level < IMT_DEPTH; ++level) {
            bytes32 sibling;
            if (idx % 2 == 0) {
                sibling = _siblingAt(self, level, idx + 1);
                currentHash = Merkle.efficientHash(currentHash, sibling);
            } else {
                sibling = _siblingAt(self, level, idx - 1);
                currentHash = Merkle.efficientHash(sibling, currentHash);
            }
            idx /= 2;
            self.nodes[level + 1][idx] = currentHash;
        }
        return currentHash;
    }

    /// @dev Read a node, falling back to the level's zero hash when no value has been written.
    /// Safe because every real leaf hash is `keccak256(...)` ≠ 0.
    function _siblingAt(IMT storage self, uint256 _level, uint256 _index) private view returns (bytes32) {
        bytes32 node = self.nodes[_level][_index];
        return node == bytes32(0) ? self.zeros[_level] : node;
    }
}
