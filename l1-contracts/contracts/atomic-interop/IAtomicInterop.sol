// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Per-`(flowId, specHash)` lifecycle on each L2 escrow in the L1-free atomic flow.
///
/// Unlike the L1-coordinated `dummy-interop` stack, no central linker authorizes settlement.
/// Each chain independently transitions a leg once a caller proves — against an *imported*
/// global interop-IMT root — that every leg of the flow was committed before the deadline
/// (happy path), or that some leg is provably missing across the deadline boundary (refund).
///
///   `Unset -> Committed -> Finalized` (happy)
///   `Unset -> Committed -> Refunded`  (timeout)
enum PartState {
    Unset,
    Committed,
    Finalized,
    Refunded
}

/// @notice One conditional transfer that lives entirely on a single chain (`chainId`).
///
/// A flow is a set of legs, possibly on different chains. The flow's atomicity is enforced
/// purely by proofs: a leg may only finalize once *all* legs of the flow have appended their
/// commit value to their chain's interop IMT within the deadline. There is no L1 coordinator.
///
/// `payer` locks `amount` of `token` on `chainId` at commit time; `payee` receives it on
/// finalize. Cross-chain intent is expressed by composing legs on different chains into one
/// flow, so that either both settle or both refund.
// SB instead of the struct below, use the following struct that was used for hte L1 interop:
// ```
/* struct SendSpec {
    uint256 destChainId;
    address recipient;
    uint256 originChainId;
    address originToken;
    uint256 amount;
    bytes erc20Data;
    address depositor;
}
*/
// As the struct that we have right now does not specify the recipients chain etc
struct FlowLeg {
    uint256 chainId;
    address token;
    uint256 amount;
    address payer;
    address payee;
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

/// @notice Inclusion proof that a leg's commit value is present in its chain's interop IMT, and
/// that this IMT root was exposed in a global interop-IMT root imported on the verifying L2 with an
/// L1 timestamp not later than the flow deadline.
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
