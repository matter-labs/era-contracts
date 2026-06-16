// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTreeLib, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. A thin shell over the shared fixed-depth Indexed Merkle
/// Tree engine ({IndexedMerkleTreeLib}): it owns the `_appender` ACL, the `initialize` wiring, and
/// the L2->L1 root publication, while the engine owns the tree storage, insert/update logic, leaf
/// hashing, and Merkle paths.
///
/// On every insert (and the head seed) it publishes `abi.encode(root, block.timestamp)` to L1 via
/// the L2->L1 messenger. The bundled timestamp is the snapshot time consuming chains compare to a
/// flow deadline; its integrity is guaranteed by the batch validity proof, and consuming chains
/// authenticate the message against the interop root they import for the settling batch (see
/// {AtomicInteropProof}).
///
/// Deployed in L2 userspace (no constructor); wiring is done in `initialize`.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using IndexedMerkleTreeLib for IMT;

    /// @dev The append-only indexed tree. `_appender` (below) doubles as the "initialized" flag.
    IMT internal _imt;

    /// @dev The {AtomicFlowEscrow} allowed to insert commit values.
    address internal _appender;

    /// @notice One-shot initializer. Sets up the IMT (seeding the `{0,0,0}` head leaf at index 0) and
    /// publishes the seed root.
    /// @param _escrow The {AtomicFlowEscrow} allowed to insert commit values.
    function initialize(address _escrow) external {
        if (_appender != address(0)) revert CommitmentTreeAlreadyInitialized();
        if (_escrow == address(0)) revert CommitmentTreeZeroAppender();
        _appender = _escrow;

        _imt.setup();
        bytes32 seedRoot = _imt.root();
        _publishRoot(seedRoot);
        emit RootPublished(0, seedRoot, block.timestamp);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != _appender) revert CommitmentTreeNotAppender(msg.sender);
        // Value / low-nullifier validation (non-zero, no duplicates, correct bracket) is enforced by
        // the engine and surfaces its own `IMT*` errors.
        (newIndex, newRoot) = _imt.insert(_value, _lowNullifierIndex);
        _publishRoot(newRoot);
        emit RootPublished(newIndex, newRoot, block.timestamp);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _imt.root();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafCount() external view returns (uint256) {
        return _imt.leafCount;
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafAt(uint256 _index) external view returns (IMTLeaf memory) {
        return _imt.leaves[_index];
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function merklePath(uint256 _index) external view returns (bytes32[] memory) {
        return _imt.merklePath(_index);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function appender() external view returns (address) {
        return _appender;
    }

    /// @dev Publishes `abi.encode(root, block.timestamp)` to L1. The encoding must match what
    /// {AtomicInteropProof} reconstructs when authenticating the message.
    function _publishRoot(bytes32 _root) internal {
        // slither-disable-next-line unused-return
        L2ContractHelper.sendMessageToL1(abi.encode(_root, block.timestamp));
    }
}
