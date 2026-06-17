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

/// @notice Inclusion proof that a leg's commit value is present in its source chain's interop IMT
/// as of a root snapshot that settled no later than the flow deadline (a settlement-layer block
/// number).
///
/// Authentication has two layers, both resolved against the interop root the verifying chain imported
/// for `(sourceChainId, batchNumber)`:
///   1. The origin {L2InteropCommitmentTree}'s `abi.encode(chainImtRoot)` L2->L1 message (sender
///      pinned to the canonical commitment-tree address) is proven included; this authenticates the
///      root.
///   2. `leaf` (with `leaf.value == commitValue`) at `imtLeafIndex` with `imtProof` hashes up to
///      `chainImtRoot` (delegated to {IndexedMerkleTreeLib.verifyInclusion}).
/// The settlement-layer (SL) block number the root settled at is NOT carried as a struct field — that
/// would be spoofable. It is parsed in-module from `messageProof` (the same multi-hop proof the
/// verifier checks) via {MessageHashing._getProofData}, so it is bound to the verified
/// `interopRoots(SL, slBlock)`. The manager then requires `slBlock <= deadline`.
/// @dev `batchNumber` is the source chain's top-level batch number passed to the message verifier and
/// to `_getProofData`.
struct ImtInclusionProof {
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

/// @notice Non-inclusion proof used on the timeout/refund path. O(log n) thanks to the indexed tree.
///
/// Proves the target commit value was absent from its chain's interop IMT as of an authenticated root
/// whose settlement-layer block number (parsed in-module from `messageProof`) is strictly after the
/// deadline. Because the IMT is append-only, absence in a post-deadline snapshot implies absence at
/// the deadline, so the leg can no longer be committed in time and the flow cannot finalize. Same
/// two-layer authentication as {ImtInclusionProof} (the SL block is likewise derived from the proof,
/// not a struct field); membership is replaced by the low-nullifier bracket
/// ({IndexedMerkleTreeLib.verifyNonInclusion}).
struct ImtNonInclusionProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    IMTLeaf lowLeaf;
    uint256 lowLeafIndex;
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
    ImtInclusionProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));
