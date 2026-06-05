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
/// commit leaf to their chain's interop IMT within the deadline. There is no L1 coordinator.
///
/// `payer` locks `amount` of `token` on `chainId` at commit time; `payee` receives it on
/// finalize. Cross-chain intent is expressed by composing legs on different chains into one
/// flow (e.g. Alice's leg on chain A and Bob's leg on chain B), so that either both settle
/// or both refund.
struct FlowLeg {
    uint256 chainId;
    address token;
    uint256 amount;
    address payer;
    address payee;
}

/// @notice Inclusion proof that a leg's commit leaf is present in its chain's interop IMT,
/// and that this IMT root was exposed in a global interop-IMT root imported on the verifying
/// L2 with an L1 timestamp not later than the flow deadline.
///
/// Layered proof (leaf -> chain IMT root -> global IMT root -> imported root @ block):
///   1. `commitLeaf` at `imtLeafIndex` with `imtProof` hashes up to `chainImtRoot`.
///   2. `globalLeaf(chainId, chainImtRoot)` at `globalLeafIndex` with `globalProof` hashes up
///      to the global root that the L2 importer stored for `l1BlockNumber`.
///   3. The importer's recorded L1 timestamp for `l1BlockNumber` must be `<= deadline`.
struct ImtInclusionProof {
    uint256 chainId;
    bytes32 chainImtRoot;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
    uint256 globalLeafIndex;
    bytes32[] globalProof;
    uint256 l1BlockNumber;
}

/// @notice Non-inclusion proof used on the timeout/refund path.
///
/// Proves that, across the deadline boundary, the target leg's commit leaf was absent from
/// its chain's interop IMT and that the chain added nothing in the window in which it could
/// still have been counted:
///   - `g1` is an imported global root whose L1 timestamp is `<= deadline`; the target chain's
///     IMT root within it is `chainImtRoot`, proven by `globalProofG1` at `globalLeafIndex`.
///   - `g2` is an imported global root whose L1 timestamp is `> deadline`; the target chain's
///     IMT root within it is identical (`chainImtRoot`), proven by `globalProofG2`. The
///     identical root means the chain settled no new leaves between `g1` and a point past the
///     deadline — closing the "inserted just past the boundary" window the spec calls out.
///   - `leaves` is the full ordered leaf set of the chain's IMT at `chainImtRoot`; recomputing
///     the incremental root must reproduce `chainImtRoot`, and the target commit leaf must not
///     appear among them.
struct ImtNonInclusionProof {
    uint256 chainId;
    bytes32 chainImtRoot;
    uint256 globalLeafIndex;
    uint256 l1BlockNumberBeforeDeadline;
    bytes32[] globalProofG1;
    uint256 l1BlockNumberAfterDeadline;
    bytes32[] globalProofG2;
    bytes32[] leaves;
}

/// @dev Empty-leaf / zero value of every interop IMT and of the global IMT. `bytes32(0)` keeps
/// the off-chain engine's incremental-root math simple; real commit leaves are keccak digests
/// and never collide with it.
bytes32 constant IMT_EMPTY_LEAF = bytes32(0);

/// @dev Domain tag prepended to the preimage of a commit leaf so leaves cannot be confused with
/// other hashes. `commitLeaf = keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, specHash))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
