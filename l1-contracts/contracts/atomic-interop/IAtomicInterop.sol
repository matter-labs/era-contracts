// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, bundleHash)` source-leg lifecycle on each {AtomicFlowManager} in the
/// atomic interop flow.
///
///   Source happy path: `Unset -> Committed` (the burn happens during `InteropCenter.sendBundle` via
///   the normal `initiateIndirectCall`; `AtomicFlowManager.append` records the leg as `Committed`,
///   which is terminal on the happy path — the destination mint is driven by
///   `L2InteropHandler.executeAtomicBundle`, which has its own bundle-level replay guard).
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
///     value (`leaf.value == commitValue`);
///   - non-inclusion ({AtomicInteropProof.verifyTimeoutAbsence}, timeout/refund path): `leaf` is the
///     low-nullifier (predecessor) leaf that brackets the absent commit value.
/// The finality / timeout conditions the proofs are checked against (which IMT snapshot, which clock
/// bounds) are described in the {AtomicInteropProof} library header.
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
/// being folded into the chain batch leaf.
/// @dev `batchNumber` is the source chain's top-level batch number passed to the leaf verifier and
/// to `_getProofData`.
/// @dev `provesAgainstBeginRoot` selects the timeout branch: `true` authenticates `chainImtRoot` as
/// the batch-BEGIN IMT root (leaf 2), `false` as the batch-END root (leaf 3). A bool (rather than a
/// raw leaf index) constrains the choice to the two IMT leaves, so authentication can never be
/// pointed at the logs/multichain leaves.
struct ImtProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    bool provesAgainstBeginRoot;
    bytes32[] settlementProof;
    IMTLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
}

/// @notice The full `flowId` preimage — the single canonical field set the id is hashed over:
/// `flowId = keccak256(abi.encode(preimage))`.
/// It is supplied by the sender in the `atomicBundle` ERC-7786 attribute and embedded (with the id)
/// in {AtomicFlow}, so the send and finalize/refund paths hash one shape and cannot drift. At send
/// time the {AtomicFlowManager} recomputes `flowId` from these fields and requires the committing
/// bundle's hash to be one of `legBundleHashes` (with this chain as its declared source), so a bundle
/// can never be committed under a `flowId` that does not actually contain it — a wrong or stale
/// preimage (e.g. an off-chain `bundleHash` prediction invalidated by an upgrade between preview and
/// send) reverts the send instead of stranding the burned funds in an unfinalizable, unrefundable leg.
/// @param version Version of the AtomicFlowPreimage (same convention as `InteropBundle.version` /
/// `InteropCall.version`). Must be a version the {AtomicFlowManager} supports — currently only
/// {ATOMIC_FLOW_PREIMAGE_VERSION} — validated identically on every path that hashes a preimage
/// (`append`, finalize, refund). A new version is added alongside the old one rather than replacing it,
/// so flows already in flight under an older version stay finalizable and refundable (no drain). Being
/// the first hashed field, it also keeps ids of one preimage version distinct from — and non-aliasing
/// with — ids hashed over any other version.
/// @param deadline The flow deadline (a settlement-layer timestamp).
/// @param settlementLayerChainId The single settlement layer every leg must settle on; committed in
/// `flowId` and asserted equal to each proof's resolved `slChainId`.
/// @param legBundleHashes All legs' bundle hashes, strictly ascending (canonical order + dedup).
/// @param legSourceChainIds Each leg's source chain id, aligned 1:1 with `legBundleHashes`. May repeat
/// and need not be ascending. Every entry must be the sending chain itself or a Bridgehub-registered
/// interop chain — a chain with no MessageRoot presence could never prove its leg committed or absent,
/// which would strand the whole flow, so `append` rejects it at send time.
struct AtomicFlowPreimage {
    bytes1 version;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legSourceChainIds;
}

/// @notice The definition of an atomic flow: `flowId` plus the preimage it is hashed from, consumed by
/// the finalize path ({AtomicFlowManager.requireFlowFinalized}) and the refund path
/// ({AtomicFlowManager.authorizeRefund}); the supplied `flowId` is always recomputed from `preimage`
/// and matched before use.
/// @param flowId `keccak256(abi.encode(preimage))`.
/// @param preimage The hashed field set (see {AtomicFlowPreimage}).
struct AtomicFlow {
    bytes32 flowId;
    AtomicFlowPreimage preimage;
}

/// @notice The full atomicity proof a destination needs to execute an atomic bundle: the flow definition
/// plus one IMT inclusion proof per leg. Passed as one calldata reference to
/// `L2InteropHandler.executeAtomicBundle` / `AtomicFlowManager.requireFlowFinalized`.
/// @param flow The flow definition (see {AtomicFlow}).
/// @param proofs One inclusion proof per leg, in `flow.preimage.legBundleHashes` order.
struct AtomicFinalityProof {
    AtomicFlow flow;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));

/// @dev The current {AtomicFlowPreimage.version} (same versioning convention as {INTEROP_BUNDLE_VERSION}
/// / {INTEROP_CALL_VERSION}), and today the only accepted one. A new value is introduced whenever the
/// {AtomicFlowPreimage} field set or its canonicalization changes; each version is validated under its
/// own rules, so a preimage of one version can never be accepted — or hash to the same `flowId` — under
/// the rules of another. Introducing a new version does not retire the old one: the {AtomicFlowManager}
/// accepts both on every path (append/finalize/refund) so in-flight prior-version flows stay finalizable
/// and refundable.
bytes1 constant ATOMIC_FLOW_PREIMAGE_VERSION = 0x01;
