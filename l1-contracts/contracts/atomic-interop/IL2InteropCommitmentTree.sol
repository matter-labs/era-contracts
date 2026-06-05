// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Per-chain append-only interop IMT. Whenever a participant "does their part" in a
/// flow, a leaf is appended here. The chain's current root is what the operator exposes on L1
/// (into {IGlobalInteropIMT}) when the batch settles; the full leaf set is the IMT preimage the
/// DA commitment covers, which the off-chain IMT engine reads back to build inclusion proofs.
///
/// Deployed in L2 userspace (CREATE2), so it has no constructor — wiring is done in `initialize`.
interface IL2InteropCommitmentTree {
    /// @notice Emitted for every appended leaf. `root` is the tree root *after* the append, and
    /// `index` is the leaf's position; together with the full event log the engine reconstructs
    /// the tree at any historical leaf count.
    event CommitmentAppended(uint256 indexed index, bytes32 indexed leaf, bytes32 root);

    /// @notice Append a leaf to the IMT. Callable only by the configured appender (the escrow).
    /// @param _leaf The leaf to append (a domain-tagged commit-leaf digest).
    /// @return index The position assigned to the leaf.
    /// @return root The new tree root.
    function appendCommitment(bytes32 _leaf) external returns (uint256 index, bytes32 root);

    /// @notice The current IMT root.
    function root() external view returns (bytes32);

    /// @notice Number of leaves appended so far (next leaf index).
    function leafCount() external view returns (uint256);

    /// @notice The current tree height (number of levels, excluding the root).
    function height() external view returns (uint256);

    /// @notice The address allowed to append (the escrow).
    function appender() external view returns (address);
}
