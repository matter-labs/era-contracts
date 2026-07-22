// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain append-only **Indexed Merkle Tree** of atomic-interop commit values, supporting
/// O(log n) proofs of both membership and non-membership. The tree publishes nothing itself: the
/// ZKsync OS bootloader snapshots the root at every batch boundary into the chain batch root, which
/// consuming chains authenticate via {AtomicInteropProof}. Deployed as an L2 genesis predeploy (no
/// constructor; seeded in `initL2`). See {protocol-docs/atomic-interop.md#contracts}.
interface IL2InteropCommitmentTree {
    /// @notice Emitted whenever the root changes. For off-chain indexing only — cross-chain consumers
    /// read the root from the chain batch root, not from events or messages.
    event RootUpdated(uint256 indexed leafIndex, bytes32 root);

    /// @notice Insert `_value` into the indexed tree. Callable only by the configured appender.
    /// @param _value The value to insert (a domain-tagged commit value, never 0).
    /// @param _lowNullifierIndex Index of the existing leaf `L` with `L.value < _value` and
    /// (`L.nextValue == 0` or `_value < L.nextValue`). The caller (or the IMT engine) computes it
    /// from the current leaf set.
    /// @return newIndex The slot assigned to the inserted leaf.
    /// @return newRoot The new tree root.
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot);

    /// @notice The current IMT root.
    function root() external view returns (bytes32);

    /// @notice Number of leaf slots in use (includes the head leaf at index 0).
    function leafCount() external view returns (uint256);

    /// @notice The leaf stored at `_index`.
    function leafAt(uint256 _index) external view returns (IMTLeaf memory);

    /// @notice The fixed-depth Merkle path (siblings, leaf level up) for the leaf at `_index`.
    function merklePath(uint256 _index) external view returns (bytes32[] memory);

    /// @notice One-time L2 initialization performed by the genesis upgrade: seeds the IMT.
    function initL2() external;

    /// @notice The address allowed to insert (the canonical {AtomicFlowManager}).
    function appender() external view returns (address);
}
