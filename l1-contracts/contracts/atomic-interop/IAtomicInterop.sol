// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Per-`(flowId, specHash)` lifecycle on each L2 escrow in the L1-free atomic flow. Mirrors
/// the `dummy-interop` `SpecState`, but transitions are gated by IMT proofs instead of an L1 linker.
///
///   Source:      `Unset -> Committed -> Executable -> Executed` (happy),
///                `Unset -> Committed -> Revertable -> Reverted` (timeout).
///   Destination: `Unset -> Executable -> Executed`.
enum SpecState {
    Unset,
    Committed,
    Executable,
    Executed,
    Revertable,
    Reverted
}

/// @notice Declarative description of one cross-chain asset transfer (identical instance known to
/// source and destination), reused from the L1-coordinated interop stack so the asset mechanics can
/// route through the asset router / native token vault exactly like `L2FlowEscrow`.
///
/// `assetId` is derived externally as
/// `keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken))`.
/// `depositor` carries the source-side payer so the escrow needs no separate depositor mapping.
struct SendSpec {
    uint256 destChainId;
    address recipient;
    uint256 originChainId;
    address originToken;
    uint256 amount;
    bytes erc20Data;
    address depositor;
}

/// @notice A leaf of an Indexed Merkle Tree. In addition to its own `value`, each leaf points to
/// the next-larger value currently in the tree (`nextValue`) at slot `nextIndex`, forming a sorted
/// singly-linked list over the append-only leaf array. This is what makes non-membership provable
/// in O(log n): a single "low nullifier" leaf `L` with `L.value < v < L.nextValue` (or
/// `L.nextValue == 0`, meaning `L` is the current maximum) certifies that `v` is absent.
///
/// `value == 0` is reserved for the head leaf (`{0, 0, 0}`) seeded at index 0; real commit values
/// are keccak digests cast to uint256 and are never 0 in practice.
struct IndexedLeaf {
    uint256 value;
    uint256 nextValue;
    uint256 nextIndex;
}

/// @notice Inclusion proof that a spec's commit value is present in its origin chain's interop IMT,
/// and that this IMT root was exposed in a global interop-IMT root imported on the verifying L2 with
/// an L1 timestamp not later than the flow deadline.
///
/// Layered proof:
///   1. `leaf` (with `leaf.value == commitValue`) at `imtLeafIndex` with `imtProof` hashes up to
///      `chainImtRoot`.
///   2. `globalLeaf(chainId, chainImtRoot)` at `globalLeafIndex` with `globalProof` hashes up to the
///      global root the L2 importer stored for `l1BlockNumber`.
///   3. The importer's recorded L1 timestamp for `l1BlockNumber` must be `<= deadline`.
struct ImtInclusionProof {
    uint256 chainId;
    bytes32 chainImtRoot;
    IndexedLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
    uint256 globalLeafIndex;
    bytes32[] globalProof;
    uint256 l1BlockNumber;
}

/// @notice Non-inclusion proof used on the timeout/refund path. O(log n) thanks to the indexed tree.
///
/// Proves that the target commit value was absent from its chain's interop IMT across the deadline
/// boundary, so the flow can no longer finalize:
///   - `lowLeaf` is the low-nullifier leaf: `lowLeaf.value < commitValue` and
///     (`lowLeaf.nextValue == 0` or `commitValue < lowLeaf.nextValue`); its inclusion in
///     `chainImtRoot` is shown by `imtProof` at `lowLeafIndex`. This certifies non-membership.
///   - `chainImtRoot` is shown inside an imported global root with L1 timestamp `<= deadline`
///     (`globalProofG1` against the root for `l1BlockNumberBeforeDeadline`) AND inside an imported
///     global root with L1 timestamp `> deadline` (`globalProofG2` for `l1BlockNumberAfterDeadline`).
///     Identical `chainImtRoot` on both sides means the chain settled nothing new across the
///     boundary — closing the "inserted just past the boundary" / L1-reorg window.
struct ImtNonInclusionProof {
    uint256 chainId;
    bytes32 chainImtRoot;
    IndexedLeaf lowLeaf;
    uint256 lowLeafIndex;
    bytes32[] imtProof;
    uint256 globalLeafIndex;
    uint256 l1BlockNumberBeforeDeadline;
    bytes32[] globalProofG1;
    uint256 l1BlockNumberAfterDeadline;
    bytes32[] globalProofG2;
}

/// @dev Empty / zero value of every Merkle tree (chain IMT, global tree, history tree). `bytes32(0)`
/// keeps the off-chain engine's math simple; real leaf hashes are keccak digests.
bytes32 constant IMT_EMPTY_LEAF = bytes32(0);

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes. `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, specHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
