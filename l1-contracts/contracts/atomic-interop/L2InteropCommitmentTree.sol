// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {CommitmentTreeNotAppender} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. A thin shell over the shared dynamic-height Indexed Merkle
/// Tree engine ({IndexedMerkleTree}): it owns the `_appender` ACL and the `initialize` seeding, while
/// the engine owns the tree storage, insert/update logic, leaf hashing, and Merkle paths.
///
/// The tree publishes nothing itself. The ZKsync OS bootloader reads the root **directly from this
/// contract's storage** at every batch boundary and commits both snapshots (batch begin and batch end)
/// as dedicated leaves of the batch's chain batch root (see {ChainBatchRootTree}). Consuming chains
/// authenticate a claimed root as that leaf against the interop root they import for the settling
/// batch (see {AtomicInteropProof}); the deadline is checked against the batch's `l1Timestamp`, which
/// the settlement layer assigns and which is re-derived from the same inclusion proof.
///
/// @dev STORAGE LAYOUT IS CONSENSUS-CRITICAL. The bootloader reads the cached root from
/// `_currentRoot` — **fixed slot 0** — at every batch boundary. The cache exists precisely because
/// the underlying dynamic-height engine has no fixed root slot (`FullMerkle` keeps the root at
/// `_nodes[_height][0]`, which moves as the tree grows); a dedicated slot gives the bootloader a
/// stable one-slot ABI that survives engine-internal changes. `_currentRoot` MUST stay at slot 0
/// and MUST be updated on every root change; an uninitialized tree reads as `bytes32(0)`, matching
/// the "no tree deployed" reading on chains without the atomic stack.
///
/// Deployed in L2 userspace (no constructor); the one-time seeding is done in `initialize`.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using IndexedMerkleTree for IMT;

    /// @dev Cache of the current IMT root, mirrored from the engine on every change. MUST stay at
    /// slot 0 — the bootloader reads this slot directly (see contract doc).
    bytes32 internal _currentRoot;

    /// @dev The append-only indexed tree. A non-zero `_imt.tree._leafNumber` doubles as the "initialized" flag.
    IMT internal _imt;

    /// @notice One-shot initializer: seeds the IMT (the `{0,0,0}` head leaf at index 0). The appender
    /// is the canonical {AtomicFlowManager} (a fixed built-in address), so there is no wiring
    /// parameter; `_imt.setup()` reverts if the tree was already seeded.
    function initialize() external {
        _imt.setup();
        bytes32 seedRoot = _imt.root();
        _currentRoot = seedRoot;
        emit RootUpdated(0, seedRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != appender()) revert CommitmentTreeNotAppender(msg.sender);
        // Value / low-nullifier validation (non-zero, no duplicates, correct bracket) is enforced by
        // the engine and surfaces its own `IMT*` errors.
        (newIndex, newRoot) = _imt.insert(_value, _lowNullifierIndex);
        _currentRoot = newRoot;
        emit RootUpdated(newIndex, newRoot);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _currentRoot;
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
}
