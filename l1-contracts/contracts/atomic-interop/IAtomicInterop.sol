// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, bundleHash)` source-leg lifecycle on each {AtomicFlowManager} in the
/// L1-free atomic interop flow.
///
///   Source happy path: `Unset -> Committed` (the burn happens during `InteropCenter.sendBundle` via
///   the normal `initiateIndirectCall`; `AtomicFlowManager.append` records the leg as `Committed`,
///   which is terminal on the happy path — the destination mint is driven by
///   `InteropHandler.executeAtomicBundle`, which has its own bundle-level replay guard).
///   Source timeout path: `Unset -> Committed -> Revertable -> Reverted`.
///
/// Destination execution is NOT tracked here: the {InteropHandler}'s own `bundleStatus` set is the
/// double-execute guard, exactly as for a normal interop bundle.
enum LegState {
    Unset,
    Committed,
    Revertable,
    Reverted
}

/// @notice A single IMT proof against a source chain's interop commitment tree, used both ways:
///   - inclusion ({AtomicInteropProof.verifyInclusion}): `leaf` is the leaf holding the leg's commit
///     value (`leaf.value == commitValue`), proven present as of a root that settled no later than the
///     flow deadline;
///   - non-inclusion ({AtomicInteropProof.verifyTimeoutAdjacency}, timeout/refund path): `leaf` is the
///     low-nullifier (predecessor) leaf that brackets the absent commit value, proven against a root
///     that settled strictly after the deadline. Because the IMT is append-only, absence in a
///     post-deadline snapshot implies absence at the deadline, so the leg can no longer finalize.
///
/// The two structs were identical in layout, so they are unified; the meaning of `leaf` (the value's
/// own leaf vs. its predecessor) is fixed by which verify function consumes the proof.
///
/// Authentication has two layers, both resolved against an SL aggregation root the verifying chain
/// imported (`interopRoots[slChainId][slBlock]`; the claimed `(sourceChainId, batchNumber)` binds via
/// the source chain's chain-id leaf inside that root):
///   1. The origin {L2InteropCommitmentTree}'s `abi.encode(chainImtRoot)` L2->L1 message (sender
///      pinned to the canonical commitment-tree address) is proven included; this authenticates the
///      root.
///   2. `leaf` at `imtLeafIndex` with `imtProof` hashes up to `chainImtRoot` (delegated to
///      {IndexedMerkleTree.verifyInclusion} / `verifyNonInclusion`).
/// The batch's `l1Timestamp` is not a struct field, since that would be spoofable. It is parsed in-module
/// from `messageProof` via {MessageHashing._getProofData} and is bound to the verified interop root by
/// being folded into the chain batch leaf. The proof library then enforces the `l1Timestamp` vs `deadline`
/// bound (inclusion: `l1Timestamp <= deadline`; timeout adjacency).
/// @dev `batchNumber` is the source chain's top-level batch number passed to the message verifier and
/// to `_getProofData`.
struct ImtProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    IMTLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
}

/// @notice Adjacency timeout proof: two authenticated batches pinning the missing leg as absent from the
/// last batch with `l1Timestamp <= deadline`. Grouping both `ImtProof`s into one struct also
/// keeps {AtomicFlowManager.authorizeRefund}'s stack shallow.
/// @param absence Non-inclusion proof of the missing leg's commit value at batch `N` (`t_N <= deadline`).
/// @param successor Root-authentication proof of the consecutive batch `N+1` (same source chain and
/// settlement layer) with `t_{N+1} > deadline`, pinning `N` as the last in-time batch. Its IMT membership
/// fields are unused.
struct AtomicTimeoutProof {
    ImtProof absence;
    ImtProof successor;
}

/// @notice The definition of an atomic flow: `flowId` plus the exact fields it hashes over. Grouping them
/// keeps the finalize path ({AtomicFlowManager.requireFlowFinalized}) and the refund path
/// ({AtomicFlowManager.authorizeRefund}) on one shape, so the `flowId` preimage cannot drift between them.
/// @param flowId `keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`.
/// @param deadline The flow deadline (a settlement-layer timestamp).
/// @param settlementLayerChainId The single settlement layer every leg must settle on; committed in
/// `flowId` and asserted equal to each proof's resolved `slChainId`.
/// @param legBundleHashes All legs' bundle hashes, strictly ascending (canonical order + dedup).
/// @param legSourceChainIds Each leg's source chain id, aligned 1:1 with `legBundleHashes`. May repeat
/// and need not be ascending.
struct AtomicFlow {
    bytes32 flowId;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legSourceChainIds;
}

/// @notice The full atomicity proof a destination needs to execute an atomic bundle: the flow definition
/// plus one IMT inclusion proof per leg. Passed as one calldata reference to
/// `InteropHandler.executeAtomicBundle` / `AtomicFlowManager.requireFlowFinalized`.
/// @param flow The flow definition (see {AtomicFlow}).
/// @param proofs One inclusion proof per leg, in `flow.legBundleHashes` order.
struct AtomicFinalityProof {
    AtomicFlow flow;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
