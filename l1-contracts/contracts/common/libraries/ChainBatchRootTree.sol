// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The chain batch root — the value a ZKsync OS chain commits as its batch's
/// `l2LogsTreeRoot` — is a fixed height-3 (8-leaf) keccak256 Merkle tree. This library mirrors
/// `compute_chain_batch_root` in the zksync-os bootloader bit-for-bit.
///
/// Leaf layout — the first four leaves carry the live commitments, the last four are reserved (zero):
///   0: L2 logs tree root (the batch's local L2->L1 logs tree)
///   1: multichain root (the chain's own aggregated MessageRoot, empty for now)
///   2: interop commitment tree (IMT) root at batch begin — before the batch's first block ran
///   3: interop commitment tree (IMT) root at batch end — after the batch's last block
///   4..7: reserved (zero)
///
/// Internal nodes are `keccak256(left || right)`; leaves are used directly (no separate leaf-hashing
/// step). The whole right subtree is constant ({RESERVED_SUBTREE_NODE}), so computing the root from
/// the four live leaves takes 3 keccaks. Because the reserved leaves are zero, they can later be
/// populated in place without changing the tree shape.
///
/// The IMT leaves are what make a chain's interop-commitment-tree root provable on other chains: an
/// authenticated chain batch root proves its leaf 2/3 with a 3-sibling path (see {AtomicInteropProof}).
/// The bootloader reads both snapshots directly from the {L2InteropCommitmentTree} storage — the tree
/// contract publishes no L2->L1 message.
library ChainBatchRootTree {
    /// @dev Height of the chain batch root tree; every leaf sits exactly this many hops below the root.
    uint256 internal constant TREE_DEPTH = 3;

    /// @dev Leaf index of the batch's local L2->L1 logs tree root.
    uint256 internal constant LOGS_ROOT_LEAF_INDEX = 0;

    /// @dev Leaf index of the chain's own multichain (aggregated MessageRoot) root.
    uint256 internal constant MULTICHAIN_ROOT_LEAF_INDEX = 1;

    /// @dev Leaf index of the interop commitment tree root at batch begin.
    uint256 internal constant IMT_BEGIN_ROOT_LEAF_INDEX = 2;

    /// @dev Leaf index of the interop commitment tree root at batch end.
    uint256 internal constant IMT_END_ROOT_LEAF_INDEX = 3;

    /// @dev Root of the reserved (all-zero) right subtree — a height-2 tree over the four zero
    /// leaves 4..7: `z2` where `z1 = keccak256(0 || 0)`, `z2 = keccak256(z1 || z1)`. Locked against
    /// the recomputation by a unit test.
    bytes32 internal constant RESERVED_SUBTREE_NODE =
        0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30;

    /// @dev Root of a freshly seeded interop commitment tree: the {IndexedMerkleTree} after `setup`
    /// holds only the `{value: 0, nextIndex: 0, nextValue: 0}` sentinel head leaf in a height-0
    /// {FullMerkle}, so the root is the sentinel's leaf hash `keccak256(abi.encode(0, 0, 0))`.
    /// Locked against the recomputation by a unit test.
    bytes32 internal constant EMPTY_IMT_ROOT = keccak256(abi.encodePacked(uint256(0), uint256(0), uint256(0)));

    /// @notice The chain batch root of a chain's synthetic genesis batch: no local logs, no
    /// multichain root, and the interop commitment tree in its freshly seeded (empty) state at both
    /// batch boundaries. The settlement layer appends a batch leaf with this root when a chain is
    /// registered in the `MessageRoot`, so every registered chain has at least one batch inside the
    /// shared root — a precondition of the atomic-interop timeout protocol (see {AtomicInteropProof}).
    function genesisChainBatchRoot() internal pure returns (bytes32) {
        return compute(bytes32(0), bytes32(0), EMPTY_IMT_ROOT, EMPTY_IMT_ROOT);
    }

    /// @notice Computes the chain batch root from the four live leaves.
    /// @param _logsRoot The batch's local L2->L1 logs tree root (leaf 0).
    /// @param _multichainRoot The chain's own multichain root (leaf 1).
    /// @param _imtRootBegin The interop commitment tree root at batch begin (leaf 2).
    /// @param _imtRootEnd The interop commitment tree root at batch end (leaf 3).
    function compute(
        bytes32 _logsRoot,
        bytes32 _multichainRoot,
        bytes32 _imtRootBegin,
        bytes32 _imtRootEnd
    ) internal pure returns (bytes32) {
        bytes32 liveSubtreeNode = keccak256(
            bytes.concat(
                keccak256(bytes.concat(_logsRoot, _multichainRoot)),
                keccak256(bytes.concat(_imtRootBegin, _imtRootEnd))
            )
        );
        return keccak256(bytes.concat(liveSubtreeNode, RESERVED_SUBTREE_NODE));
    }
}
