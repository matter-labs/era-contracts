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
///   - non-inclusion ({AtomicInteropProof.verifyNonInclusion}, timeout/refund path): `leaf` is the
///     low-nullifier (predecessor) leaf that brackets the absent commit value, proven against a root
///     that settled strictly after the deadline. Because the IMT is append-only, absence in a
///     post-deadline snapshot implies absence at the deadline, so the leg can no longer finalize.
///
/// The two structs were identical in layout, so they are unified; the meaning of `leaf` (the value's
/// own leaf vs. its predecessor) is fixed by which verify function consumes the proof.
///
/// Authentication has two layers, both resolved against the interop root the verifying chain imported
/// for `(sourceChainId, batchNumber)`:
///   1. The origin {L2InteropCommitmentTree}'s `abi.encode(chainImtRoot)` L2->L1 message (sender
///      pinned to the canonical commitment-tree address) is proven included; this authenticates the
///      root.
///   2. `leaf` at `imtLeafIndex` with `imtProof` hashes up to `chainImtRoot` (delegated to
///      {IndexedMerkleTreeLib.verifyInclusion} / `verifyNonInclusion`).
/// The settlement-layer (SL) block number the root settled at is NOT carried as a struct field — that
/// would be spoofable. It is parsed in-module from `messageProof` (the same multi-hop proof the
/// verifier checks) via {MessageHashing._getProofData}, so it is bound to the verified
/// `interopRoots(SL, slBlock)`. The manager then enforces the appropriate `slBlock` vs `deadline` bound.
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

/// @notice The full atomicity proof a destination needs to execute an atomic bundle: the flow
/// definition (`flowId`, every leg, `deadline`) plus one IMT inclusion proof per leg. Bundled into a
/// single calldata struct so `InteropHandler.executeAtomicBundle` / `AtomicFlowManager.requireFlowFinalized`
/// pass it as one reference.
/// @param flowId `keccak256(abi.encode(legBundleHashes, chainIds, deadline))` (both arrays ascending).
/// @param deadline The flow deadline (a settlement-layer block number).
/// @param legBundleHashes All legs' bundle hashes, strictly ascending.
/// @param chainIds The flow's participant chain ids, strictly ascending.
/// @param proofs One inclusion proof per leg, in `legBundleHashes` order.
struct AtomicFinalityProof {
    bytes32 flowId;
    uint64 deadline;
    bytes32[] legBundleHashes;
    uint256[] chainIds;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
