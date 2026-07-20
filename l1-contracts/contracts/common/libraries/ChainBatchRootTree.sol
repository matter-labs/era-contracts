// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The chain batch root of a ZKsync OS chain — a fixed height-3 (8-leaf) keccak256 Merkle
/// tree over the batch's commitments. Mirrors `compute_chain_batch_root` in the zksync-os
/// bootloader bit-for-bit. Leaf layout and rationale: {protocol-docs/message-root.md}.
library ChainBatchRootTree {
    /// @dev Height of the chain batch root tree; every leaf sits exactly this many hops below the root.
    uint256 internal constant TREE_DEPTH = 3;

    /// @dev Leaf index of the batch's local L2->L1 logs tree root. May be unused; kept so the
    /// library documents every leaf of the layout.
    uint256 internal constant LOGS_ROOT_LEAF_INDEX = 0;

    /// @dev Leaf index of the chain's own multichain (aggregated MessageRoot) root. May be unused;
    /// kept so the library documents every leaf of the layout.
    uint256 internal constant MULTICHAIN_ROOT_LEAF_INDEX = 1;

    /// @dev Leaf index of the interop commitment tree root at batch begin.
    uint256 internal constant IMT_BEGIN_ROOT_LEAF_INDEX = 2;

    /// @dev Leaf index of the interop commitment tree root at batch end.
    uint256 internal constant IMT_END_ROOT_LEAF_INDEX = 3;

    /// @dev Root of the reserved (all-zero) right subtree over leaves 4..7: `z2` where
    /// `z1 = keccak256(0 || 0)`, `z2 = keccak256(z1 || z1)`. Locked against recomputation by a unit test.
    bytes32 internal constant RESERVED_SUBTREE_NODE =
        0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30;

    /// @dev Root of a freshly seeded interop commitment tree: the hash of the `{0,0,0}` sentinel
    /// head leaf, i.e. keccak256 of 96 zero bytes. Hardcoded because Solidity re-evaluates
    /// non-literal constant expressions at every use site.
    bytes32 internal constant EMPTY_IMT_ROOT = 0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21;

    /// @notice The chain batch root of a chain's genesis batch (batch 0): zero logs and multichain
    /// roots, freshly seeded (empty) IMT at both batch boundaries. Seeded into the `MessageRoot` at
    /// chain creation; see {protocol-docs/chain-lifecycle.md}.
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
