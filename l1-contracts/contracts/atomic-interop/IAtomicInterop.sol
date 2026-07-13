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
///     value (`leaf.value == commitValue`), proven present in the batch-END IMT root of a batch whose
///     `l1Timestamp < deadline`;
///   - non-inclusion ({AtomicInteropProof.verifyTimeoutAbsence}, timeout/refund path): `leaf` is the
///     low-nullifier (predecessor) leaf that brackets the absent commit value. The proof is anchored
///     on an aggregated root created after the deadline and is checked against the batch-BEGIN IMT
///     root when the batch is late (`l1Timestamp >= deadline`), or against the batch-END IMT root of
///     the chain's LAST batch inside the aggregated root when the batch is in time. Since the IMT is
///     append-only and `begin(N) == end(N-1)`, either way absence means the value was not committed
///     in any in-time batch, so the leg can never finalize.
///
/// The meaning of `leaf` (the value's own leaf vs. its predecessor) is fixed by which verify function
/// consumes the proof.
///
/// Authentication has two layers, both resolved against an SL aggregation root the verifying chain
/// imported (`interopRoots[slChainId][slBlock]`; the claimed `(sourceChainId, batchNumber)` binds via
/// the source chain's chain-id leaf inside that root):
///   1. `chainImtRoot` is proven to be a leaf of the source batch's **chain batch root** — the fixed
///      height-3 tree the bootloader commits, whose leaves 2/3 are the IMT roots at batch begin/end
///      (see {ChainBatchRootTree}) — via `proveL2LeafInclusionShared` with `settlementProof`. The leaf
///      index (2 = begin, 3 = end) is hardcoded by the consuming verify function, and the top-tree
///      depth is enforced to be exactly {ChainBatchRootTree.TREE_DEPTH}, so the claimed value can only
///      ever be a real batch-boundary IMT root written by the bootloader.
///   2. `leaf` at `imtLeafIndex` with `imtProof` hashes up to `chainImtRoot` (delegated to
///      {IndexedMerkleTree.verifyInclusion} / `verifyNonInclusion`).
/// The batch's `l1Timestamp` is not a struct field, since that would be spoofable. It is parsed in-module
/// from `settlementProof` via {MessageHashing._getProofData} and is bound to the verified interop root by
/// being folded into the chain batch leaf. The proof library then enforces the `l1Timestamp` vs `deadline`
/// bound (inclusion: `l1Timestamp < deadline`; timeout: anchored on an aggregated root created after the
/// deadline, absence from the begin root of a late batch or the end root of the chain's last batch in
/// that root).
/// @dev `batchNumber` is the source chain's top-level batch number passed to the leaf verifier and
/// to `_getProofData`.
struct ImtProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    bytes32[] settlementProof;
    IMTLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
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
