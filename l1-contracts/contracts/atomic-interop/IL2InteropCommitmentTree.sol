// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain Indexed Merkle Tree of interop commit values. Whenever a participant does their
/// part in a flow, the leg's commit value is inserted here. Each {IMTLeaf} points to the next-larger
/// value, giving O(log n) proofs of both membership and non-membership (via a "low nullifier" leaf).
/// Every insert publishes `abi.encode(root)` to L1 through the L2->L1 messenger; consuming chains
/// authenticate that message against the interop root imported for the settling batch (see
/// {AtomicInteropProof}), which is what makes the root trustworthy. The tree publishes only the root,
/// no timestamp: the deadline is checked against the batch's settlement timestamp `t`, which is folded
/// into the chain batch leaf and re-derived from the same inclusion proof.
///
/// Deployed in L2 userspace via CREATE2, so it has no constructor — wiring is done in `initialize`.
interface IL2InteropCommitmentTree {
    /// @notice Emitted after a new root is published to L1: the `{0,0,0}` head seed at `initialize`,
    /// then one per inserted value.
    event RootPublished(uint256 indexed leafIndex, bytes32 root);

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

    /// @notice The address allowed to insert (the escrow).
    function appender() external view returns (address);
}
