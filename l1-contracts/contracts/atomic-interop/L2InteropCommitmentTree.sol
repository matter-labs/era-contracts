// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {CommitmentTreeNotAppender} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. A thin shell over the shared dynamic-height Indexed Merkle
/// Tree engine ({IndexedMerkleTree}): it owns the `_appender` ACL, the `initialize` wiring, and
/// the L2->L1 root publication, while the engine owns the tree storage, insert/update logic, leaf
/// hashing, and Merkle paths.
///
/// On every insert (and the head seed) it publishes `abi.encode(root)` to L1 via the L2->L1 messenger.
/// Consuming chains authenticate that message against the interop root they import for the settling
/// batch (see {AtomicInteropProof}); the snapshot time used for the deadline check is the
/// settlement-layer block number, derived in-module from the same inclusion proof, so the tree itself
/// no longer bundles any (operator-set) timestamp.
///
/// Deployed in L2 userspace (no constructor); wiring is done in `initialize`.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using IndexedMerkleTree for IMT;

    /// @dev The append-only indexed tree. A non-zero `_imt.tree._leafNumber` doubles as the "initialized" flag.
    IMT internal _imt;

    /// @notice One-shot initializer: seeds the IMT (the `{0,0,0}` head leaf at index 0) and publishes
    /// the seed root. The appender is the canonical {AtomicFlowManager} (a fixed built-in address), so
    /// there is no wiring parameter; `_imt.setup()` reverts if the tree was already seeded.
    function initialize() external {
        _imt.setup();
        bytes32 seedRoot = _imt.root();
        _publishRoot(seedRoot);
        emit RootPublished(0, seedRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != appender()) revert CommitmentTreeNotAppender(msg.sender);
        // Value / low-nullifier validation (non-zero, no duplicates, correct bracket) is enforced by
        // the engine and surfaces its own `IMT*` errors.
        (newIndex, newRoot) = _imt.insert(_value, _lowNullifierIndex);
        _publishRoot(newRoot);
        emit RootPublished(newIndex, newRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _imt.root();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafCount() external view returns (uint256) {
        return _imt.tree._leafNumber;
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
    function appender() public view virtual returns (address) {
        return L2_ATOMIC_FLOW_MANAGER_ADDR;
    }

    /// @dev Publishes `abi.encode(root)` to L1. The encoding must match what {AtomicInteropProof}
    /// reconstructs when authenticating the message.
    function _publishRoot(bytes32 _root) internal {
        // slither-disable-next-line unused-return
        L2ContractHelper.sendMessageToL1(abi.encode(_root));
    }
}
