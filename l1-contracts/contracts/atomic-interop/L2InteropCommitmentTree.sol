// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IMT_EMPTY_LEAF} from "./IAtomicInterop.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. Thin wrapper around {DynamicIncrementalMerkle} that
/// records the append-only interop commitment tree for one chain.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    /// @dev The append-only tree. `setup` is called in `initialize` with the empty-leaf zero so
    /// the zero cascade matches the proof library and the off-chain engine.
    DynamicIncrementalMerkle.Bytes32PushTree internal _tree;

    /// @dev The escrow allowed to append. Also serves as the "initialized" flag.
    address internal _appender;

    /// @notice One-shot initializer. Sets the appender and seeds the empty tree.
    /// @param _escrow The {AtomicFlowEscrow} allowed to append commit leaves.
    function initialize(address _escrow) external {
        if (_appender != address(0)) revert CommitmentTreeAlreadyInitialized();
        if (_escrow == address(0)) revert CommitmentTreeZeroAppender();
        _appender = _escrow;
        _tree.setup(IMT_EMPTY_LEAF);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function appendCommitment(bytes32 _leaf) external returns (uint256 index, bytes32 newRoot) {
        if (msg.sender != _appender) revert CommitmentTreeNotAppender(msg.sender);
        (index, newRoot) = _tree.push(_leaf);
        emit CommitmentAppended(index, _leaf, newRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _tree.root();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafCount() external view returns (uint256) {
        return _tree._nextLeafIndex;
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function height() external view returns (uint256) {
        return _tree.height();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function appender() external view returns (address) {
        return _appender;
    }
}
