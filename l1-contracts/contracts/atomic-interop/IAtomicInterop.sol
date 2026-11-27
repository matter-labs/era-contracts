// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, bundleHash)` leg state in {AtomicFlowManager}. On the leg's source: `Unset ->
/// Committed` (send; terminal on the happy path), `-> Revertable -> Reverted` (timeout path). On the
/// destination of an accepted flow's leg: `Unset -> Accepted`. A leg's source and destination differ, so
/// one chain never holds both lifecycles for a key. Destination execution is NOT tracked here — the
/// {InteropHandler}'s own `bundleStatus` is the replay guard, exactly as for a normal interop bundle.
enum LegState {
    Unset,
    Committed,
    Revertable,
    Reverted,
    Accepted
}

/// @notice A single IMT proof against a source chain's interop commitment tree, used both for
/// inclusion ({AtomicInteropProof.verifyInclusion}; `leaf` holds the commitment value) and non-inclusion
/// ({AtomicInteropProof.verifyTimeoutAbsence}; `leaf` is the low-nullifier leaf bracketing the absent
/// value). Two authentication layers: `settlementProof` proves `chainImtRoot` is the batch's
/// begin/end IMT leaf of the chain batch root against an imported interop root, and `imtProof` proves
/// `leaf` under `chainImtRoot`. See {AtomicInteropProof} for the mechanics and conditions.
/// @dev The batch's `l1Timestamp` is deliberately NOT a struct field (it would be spoofable); it is
/// re-derived from `settlementProof`, being folded into the chain batch leaf.
/// @dev `provesAgainstBeginRoot` selects the timeout branch: `true` authenticates `chainImtRoot` as
/// the batch-BEGIN IMT root (leaf 2), `false` as the batch-END root (leaf 3). A bool (not a raw leaf
/// index) so authentication can never be pointed at the logs/multichain leaves.
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

/// @notice The full `flowId` preimage: `flowId = keccak256(abi.encode(preimage))`, except that a source-only
/// flow hashes as {SourceOnlyFlowPreimage}. Supplied by the
/// sender in the `atomicBundle` ERC-7786 attribute; {AtomicFlowManager.append} recomputes `flowId`
/// from it and verifies the committing bundle is one of the legs, so a wrong or stale preimage
/// reverts the send. See {protocol-docs/atomicity/flow.md#1-atomic-send-append}.
/// @param version Preimage format version: {ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED} for new flows, or
/// {ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY} for a flow sent before accepted flows were introduced.
/// @param deadline The flow deadline (a settlement-layer timestamp).
/// @param settlementLayerChainId The single settlement layer every leg must settle on.
/// @param legBundleHashes All legs' bundle hashes, strictly ascending (canonical order + dedup).
/// @param legChainIds Each leg's source chain, aligned with `legBundleHashes` (may repeat, need not be
/// ascending).
/// @param legDestinationChainIds Each leg's destination chain, aligned with `legBundleHashes`. Empty for a
/// source-only flow. See {protocol-docs/atomicity/acceptance.md}.
struct AtomicFlowPreimage {
    bytes1 version;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legChainIds;
    uint256[] legDestinationChainIds;
}

/// @notice The preimage layout source-only flows were sent with: their `flowId` is
/// `keccak256(abi.encode(SourceOnlyFlowPreimage))`, so it does not change with {AtomicFlowPreimage}.
/// @dev Only for flows sent before accepted flows were introduced; removable once none can still be finalized
/// or refunded.
struct SourceOnlyFlowPreimage {
    bytes1 version;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legChainIds;
}

/// @notice An atomic flow definition, consumed by the finalize and refund paths; the supplied
/// `flowId` is always recomputed from `preimage` and matched before use.
/// @param flowId The hash of `preimage` (see {AtomicFlowPreimage}).
/// @param preimage The hashed field set (see {AtomicFlowPreimage}).
/// @dev `flowId` is redundant (recomputed from `preimage` and matched before use); kept for calldata
/// readability. Such recomputed-and-verified fields are acceptable on public entrypoint structs, not internal ones.
struct AtomicFlow {
    bytes32 flowId;
    AtomicFlowPreimage preimage;
}

/// @notice The full atomicity proof a destination needs to execute an atomic bundle: the flow definition
/// plus one IMT inclusion proof per commitment. Passed as one calldata reference to
/// `L2InteropHandler.executeAtomicBundle` / `AtomicFlowManager.requireFlowFinalized`.
/// @param flow The flow definition (see {AtomicFlow}).
/// @param proofs Source-only flows: one inclusion proof per leg's commit value, in `legChainIds` order.
/// Accepted flows: one inclusion proof per participating chain's participation value, in order of each
/// chain's first appearance in `legChainIds` followed by `legDestinationChainIds`. See
/// {protocol-docs/atomicity/acceptance.md#commitments}.
struct AtomicFinalityProof {
    AtomicFlow flow;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));

/// @dev Domain tag of the single value each chain of an accepted flow inserts into its own IMT. Distinct from
/// {ATOMIC_COMMIT_LEAF_TAG}, so a participation can never stand in for a commit.
/// `participationValue = uint256(keccak256(abi.encode(ATOMIC_PARTICIPATION_LEAF_TAG, flowId, chainId)))`.
bytes4 constant ATOMIC_PARTICIPATION_LEAF_TAG = bytes4(keccak256("AtomicInterop.participation.v1"));

/// @dev {AtomicFlowPreimage.version} values (same versioning convention as {INTEROP_BUNDLE_VERSION} /
/// {INTEROP_CALL_VERSION}). Each version is validated under its own rules, so a preimage of one version can
/// never be accepted — or hash to the same `flowId` — under the rules of another. New flows are sent in the
/// latest version only ({AtomicFlowManager.append}); the finalize and refund paths keep accepting earlier
/// versions, so flows sent before an upgrade stay finalizable and refundable.
/// @dev Source-only flow: only the legs' source chains commit. No longer sent; kept for flows sent before
/// accepted flows were introduced.
bytes1 constant ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY = 0x01;
/// @dev Accepted flow: each chain of the flow commits its outgoing legs, accepts its incoming legs, and then
/// inserts one participation value, all in time. See {protocol-docs/atomicity/acceptance.md}.
bytes1 constant ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED = 0x02;

/// @dev The maximum number of legs in an atomic flow. Committing a leg is cheap (at most one IMT insert), but
/// finalizing ANY leg requires verifying one full inclusion proof — a settlement-layer Merkle proof
/// plus an IMT membership proof — per commitment of the flow, i.e. one per leg, or one per participating
/// chain (at most two per leg) for an accepted flow ({AtomicFlowManager.requireFlowFinalized}), so
/// an unbounded leg count would make destination-side execution arbitrarily expensive. The cap is
/// part of preimage validation ({AtomicFlowManager._validateAndComputeFlowId}), so an oversized flow
/// is rejected identically on the append, finalize and refund paths and can never commit a leg.
uint256 constant MAX_ATOMIC_FLOW_LEGS = 8;
