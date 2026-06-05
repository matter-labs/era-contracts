// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMerkle} from "../common/libraries/FullMerkle.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IndexedLeaf, IMT_EMPTY_LEAF} from "./IAtomicInterop.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeLowNullifierNotAbove,
    CommitmentTreeLowNullifierNotBelow,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender,
    CommitmentTreeZeroValue
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. An Indexed Merkle Tree backed by {FullMerkle} (which
/// supports both in-place leaf updates and appends).
///
/// Invariant: the leaves form a sorted singly-linked list by `value`, headed by the zero leaf
/// `{0, 0, 0}` at index 0. Inserting `v` repoints the low-nullifier leaf to `v` and appends
/// `{v, oldNext, oldNextIndex}`. The leaf-hash matches {AtomicInteropProof.indexedLeafHash}, so the
/// roots/paths verify on-chain in the escrow and off-chain in the IMT engine.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using FullMerkle for FullMerkle.FullTree;

    /// @dev Underlying complete Merkle tree of leaf hashes.
    FullMerkle.FullTree internal _tree;
    /// @dev index => leaf data.
    mapping(uint256 index => IndexedLeaf leaf) internal _leaves;
    /// @dev Number of leaf slots in use (>= 1 after init: the head leaf).
    uint256 internal _leafCount;

    /// @dev The escrow allowed to insert. Also serves as the "initialized" flag.
    address internal _appender;

    /// @notice One-shot initializer. Seeds the head leaf `{0, 0, 0}` at index 0.
    /// @param _escrow The {AtomicFlowEscrow} allowed to insert commit values.
    function initialize(address _escrow) external {
        if (_appender != address(0)) revert CommitmentTreeAlreadyInitialized();
        if (_escrow == address(0)) revert CommitmentTreeZeroAppender();
        _appender = _escrow;

        _tree.setup(IMT_EMPTY_LEAF);
        IndexedLeaf memory head = IndexedLeaf({value: 0, nextValue: 0, nextIndex: 0});
        bytes32 root = _tree.pushNewLeaf(_hashLeaf(head));
        _leaves[0] = head;
        _leafCount = 1;
        // solhint-disable-next-line func-named-parameters
        emit LeafUpdated(0, 0, 0, 0, root);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != _appender) revert CommitmentTreeNotAppender(msg.sender);
        if (_value == 0) revert CommitmentTreeZeroValue();

        IndexedLeaf memory low = _leaves[_lowNullifierIndex];
        if (low.value >= _value) revert CommitmentTreeLowNullifierNotBelow(_value, low.value);
        // `nextValue == 0` means `low` is the current maximum. Otherwise the value must fall strictly
        // before `low.nextValue`; this also guarantees `_value` is not already present.
        if (low.nextValue != 0 && _value >= low.nextValue) {
            revert CommitmentTreeLowNullifierNotAbove(_value, low.nextValue);
        }

        newIndex = _leafCount;
        IndexedLeaf memory inserted = IndexedLeaf({value: _value, nextValue: low.nextValue, nextIndex: low.nextIndex});

        // Repoint the low-nullifier to the new leaf (in place).
        low.nextValue = _value;
        low.nextIndex = newIndex;
        _leaves[_lowNullifierIndex] = low;
        bytes32 rootAfterUpdate = _tree.updateLeaf(_lowNullifierIndex, _hashLeaf(low));
        // solhint-disable-next-line func-named-parameters
        emit LeafUpdated(_lowNullifierIndex, low.value, low.nextValue, low.nextIndex, rootAfterUpdate);

        // Append the new leaf.
        newRoot = _tree.pushNewLeaf(_hashLeaf(inserted));
        _leaves[newIndex] = inserted;
        _leafCount = newIndex + 1;
        // solhint-disable-next-line func-named-parameters
        emit LeafUpdated(newIndex, inserted.value, inserted.nextValue, inserted.nextIndex, newRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _tree.root();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafCount() external view returns (uint256) {
        return _leafCount;
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafAt(uint256 _index) external view returns (IndexedLeaf memory) {
        return _leaves[_index];
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function appender() external view returns (address) {
        return _appender;
    }

    /// @dev Must match {AtomicInteropProof.indexedLeafHash}.
    function _hashLeaf(IndexedLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextValue, _leaf.nextIndex));
    }
}
