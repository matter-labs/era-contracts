// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {
    FlowLeg,
    IndexedLeaf,
    IMT_EMPTY_LEAF,
    ATOMIC_COMMIT_LEAF_TAG
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";

/// @notice A {FullMerkle}-backed tree used by tests to generate Merkle paths. {FullMerkle} and the
/// chain IMT / global tree produce identical roots/paths for the same leaf hashes + zero value, so a
/// path generated here verifies against the on-chain roots.
contract FullMerkleWrapper {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal _tree;

    constructor() {
        _tree.setup(IMT_EMPTY_LEAF);
    }

    function push(bytes32 _leaf) external returns (bytes32) {
        return _tree.pushNewLeaf(_leaf);
    }

    function root() external view returns (bytes32) {
        return _tree.root();
    }

    function path(uint256 _index) external view returns (bytes32[] memory) {
        return _tree.merklePath(_index);
    }
}

/// @notice Calldata wrapper so tests can verify a Merkle path the same way the proof library does.
contract MerkleCalldataWrapper {
    function calcRoot(bytes32[] calldata _path, uint256 _index, bytes32 _leaf) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _leaf);
    }
}

/// @notice Mirrors an on-chain {IL2InteropCommitmentTree} into a {FullMerkleWrapper} so tests can
/// produce inclusion / non-inclusion Merkle paths and compute low-nullifier indices.
contract IndexedImtProver {
    /// @dev Build a FullMerkle mirror of the tree's current leaf set; returns the wrapper.
    function mirror(IL2InteropCommitmentTree _tree) public returns (FullMerkleWrapper wrapper) {
        wrapper = new FullMerkleWrapper();
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            wrapper.push(AtomicInteropTestUtils.indexedLeafHash(_tree.leafAt(i)));
        }
    }

    /// @dev Index of the low-nullifier leaf for `_value` in the tree's current state.
    function lowNullifierIndex(IL2InteropCommitmentTree _tree, uint256 _value) public view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            IndexedLeaf memory l = _tree.leafAt(i);
            if (l.value < _value && (l.nextValue == 0 || _value < l.nextValue)) {
                return i;
            }
        }
        revert("no low nullifier");
    }

    /// @dev Index of the leaf whose value == `_value` (membership).
    function indexOfValue(IL2InteropCommitmentTree _tree, uint256 _value) public view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            if (_tree.leafAt(i).value == _value) {
                return i;
            }
        }
        revert("value not present");
    }
}

/// @notice Shared pure helpers mirroring the off-chain coordinator / proof library.
library AtomicInteropTestUtils {
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    function indexedLeafHash(IndexedLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextValue, _leaf.nextIndex));
    }

    function globalLeaf(uint256 _chainId, bytes32 _chainImtRoot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chainImtRoot, _chainId));
    }

    function specHashOf(FlowLeg memory _leg) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leg));
    }

    /// @notice Computes flowId exactly as {AtomicFlowEscrow}. Both arrays must be strictly ascending.
    function computeFlowId(
        bytes32[] memory _specHashes,
        uint256[] memory _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_specHashes, _chainIds, _deadline));
    }
}
