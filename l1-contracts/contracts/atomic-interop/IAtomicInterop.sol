// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, bundleHash)` source-leg lifecycle on each {AtomicFlowManager}.
///
///   Happy path: `Unset -> Committed`. The burn happens in `InteropCenter.sendBundle` and
///   `AtomicFlowManager.append` records the leg as `Committed` (terminal on the happy path). The
///   destination mint is driven by `InteropHandler.executeAtomicBundle`, which has its own replay guard.
///   Timeout path: `Unset -> Committed -> Revertable -> Reverted`.
///
/// Destination execution is not tracked here; {InteropHandler}'s `bundleStatus` is the double-execute
/// guard, as for a normal interop bundle.
enum LegState {
    Unset,
    Committed,
    Revertable,
    Reverted
}

/// @notice A single IMT proof against a source chain's interop commitment tree, used both ways:
///   - inclusion ({AtomicInteropProof.verifyInclusion}): `leaf` holds the leg's commit value
///     (`leaf.value == commitValue`), proven present as of a root that settled no later than the deadline;
///   - non-inclusion ({AtomicInteropProof.verifyTimeoutAdjacency}, timeout/refund path): `leaf` is the
///     predecessor leaf bracketing the absent commit value, proven against a root that settled strictly
///     after the deadline. The IMT is append-only, so absence in a post-deadline snapshot implies absence
///     at the deadline and the leg can no longer finalize.
/// The two proof shapes are identical in layout and share this struct; the meaning of `leaf` is fixed by
/// which verify function consumes the proof.
///
/// Authentication has two layers, both resolved against the interop root the verifying chain imported
/// for `(sourceChainId, batchNumber)`:
///   1. The origin {L2InteropCommitmentTree}'s `abi.encode(chainImtRoot)` L2->L1 message (sender pinned
///      to the canonical commitment-tree address) is proven included, authenticating the root.
///   2. `leaf` at `imtLeafIndex` with `imtProof` hashes up to `chainImtRoot`.
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

/// @notice The full atomicity proof a destination needs to execute an atomic bundle: the flow definition
/// (`flowId`, every leg, each leg's source chain, `deadline`, the settlement layer) plus one IMT
/// inclusion proof per leg. Passed as one calldata reference to `InteropHandler.executeAtomicBundle` /
/// `AtomicFlowManager.requireFlowFinalized`.
/// @param flowId `keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`.
/// @param deadline The flow deadline (a settlement-layer timestamp).
/// @param settlementLayerChainId The single settlement layer every leg must settle on; committed in
/// `flowId` and asserted equal to each proof's resolved `slChainId`.
/// @param legBundleHashes All legs' bundle hashes, strictly ascending (canonical order + dedup).
/// @param legSourceChainIds Each leg's source chain id, aligned 1:1 with `legBundleHashes`. May repeat
/// and need not be ascending.
/// @param proofs One inclusion proof per leg, in `legBundleHashes` order.
struct AtomicFinalityProof {
    bytes32 flowId;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legSourceChainIds;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
