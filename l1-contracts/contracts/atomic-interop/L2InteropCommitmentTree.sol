// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {CommitmentTreeNotAppender} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. A thin shell over the shared dynamic-height Indexed Merkle
/// Tree engine ({IndexedMerkleTree}).
///
/// The tree publishes nothing itself. The ZKsync OS bootloader reads the root **directly from this
/// contract's storage** at every batch boundary and commits both snapshots (batch begin and batch end)
/// as dedicated leaves of the batch's chain batch root (see {ChainBatchRootTree}). Consuming chains
/// authenticate a claimed root as that leaf against the interop root they import for the settling
/// batch (see {AtomicInteropProof}); the deadline is checked against the batch's `l1Timestamp`, which
/// the settlement layer assigns and which is re-derived from the same inclusion proof.
///
/// @dev STORAGE LAYOUT IS CONSENSUS-CRITICAL. The bootloader reads the engine's root
/// `_imt.tree._nodes[_imt.tree._height][0]` directly: it loads `_height` from slot 0 and derives the
/// `_nodes[_height][0]` slot from the `_nodes` base slot 2. An uninitialized tree reads as `bytes32(0)`.
///
/// Deployed as an L2 genesis predeploy (no constructor); the one-time seeding is done in `initL2`.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using IndexedMerkleTree for IMT;

    /// @dev The append-only indexed tree. MUST stay at slot 0 — the bootloader derives the engine's
    /// root slot from this position (see contract doc). A non-zero `_imt.tree._leafNumber` also serves
    /// as the "initialized" flag.
    IMT internal _imt;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice One-time L2 initialization performed by the genesis upgrade: seeds the
    /// IMT (the `{0,0,0}` head leaf at index 0). The appender is the canonical
    /// {AtomicFlowManager} (a fixed built-in address), so there is no wiring parameter;
    /// `_imt.setup()` reverts if the tree was already seeded.
    function initL2() external onlyUpgrader {
        _imt.setup();
        emit RootUpdated(0, _imt.root());
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != appender()) revert CommitmentTreeNotAppender(msg.sender);
        // Value / low-nullifier validation (non-zero, no duplicates, correct bracket) is enforced by
        // the engine and surfaces its own `IMT*` errors.
        (newIndex, newRoot) = _imt.insert(_value, _lowNullifierIndex);
        emit RootUpdated(newIndex, newRoot);
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
}
