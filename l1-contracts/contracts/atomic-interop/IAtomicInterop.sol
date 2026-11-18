// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, bundleHash)` source-leg lifecycle in {AtomicFlowManager}: `Unset ->
/// Committed` (send; terminal on the happy path), `-> Revertable -> Reverted` (timeout path).
/// Destination execution is NOT tracked here — the {InteropHandler}'s own `bundleStatus` is the
/// replay guard, exactly as for a normal interop bundle.
enum LegState {
    Unset,
    Committed,
    Revertable,
    Reverted
}

/// @notice A single IMT proof against a source chain's interop commitment tree, used both for
/// inclusion ({AtomicInteropProof.verifyInclusion}; `leaf` holds the commit value) and non-inclusion
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

/// @notice The full `flowId` preimage: `flowId = keccak256(abi.encode(preimage))`. Supplied by the
/// sender in the `atomicBundle` ERC-7786 attribute; {AtomicFlowManager.append} recomputes `flowId`
/// from it and verifies the committing bundle is one of the legs, so a wrong or stale preimage
/// reverts the send. See {protocol-docs/atomicity/flow.md#1-atomic-send-append}.
/// @param version Preimage format version ({ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY} or
/// {ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}).
/// @param deadline The flow deadline (a settlement-layer timestamp).
/// @param settlementLayerChainId The single settlement layer every leg must settle on.
/// @param legBundleHashes All legs' bundle hashes, strictly ascending (canonical order + dedup).
/// @param legChainIds The chain whose IMT holds each of the flow's commitments (may repeat, need not
/// be ascending). Source-only flows: `n` entries, leg `i`'s source chain. Accepted flows: `2n`
/// entries, the `n` source chains followed by the `n` destination chains, both aligned with
/// `legBundleHashes`. Every entry must be the sending chain itself or a Bridgehub-registered interop
/// chain. See {protocol-docs/atomicity/acceptance.md}.
struct AtomicFlowPreimage {
    bytes1 version;
    uint64 deadline;
    uint256 settlementLayerChainId;
    bytes32[] legBundleHashes;
    uint256[] legChainIds;
}

/// @notice An atomic flow definition, consumed by the finalize and refund paths; the supplied
/// `flowId` is always recomputed from `preimage` and matched before use.
/// @param flowId `keccak256(abi.encode(preimage))`.
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
/// @param proofs One inclusion proof per entry of `flow.preimage.legChainIds`, in the same order: the
/// legs' commit values, followed (accepted flows only) by the legs' accept values.
struct AtomicFinalityProof {
    AtomicFlow flow;
    ImtProof[] proofs;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes.
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));

/// @dev Domain tag of the value a destination chain inserts into its own IMT when it accepts a leg of an
/// accepted flow. Distinct from {ATOMIC_COMMIT_LEAF_TAG}, so an acceptance can never stand in for a commit.
/// `acceptValue = uint256(keccak256(abi.encode(ATOMIC_ACCEPT_LEAF_TAG, flowId, bundleHash)))`.
bytes4 constant ATOMIC_ACCEPT_LEAF_TAG = bytes4(keccak256("AtomicInterop.accept.v1"));

/// @dev {AtomicFlowPreimage.version} values (same versioning convention as {INTEROP_BUNDLE_VERSION} /
/// {INTEROP_CALL_VERSION}). Each version is validated under its own rules, so a preimage of one version can
/// never be accepted — or hash to the same `flowId` — under the rules of another. Introducing a new version
/// does not retire the old one: the {AtomicFlowManager} accepts both on every path (append/finalize/refund)
/// so in-flight prior-version flows stay finalizable and refundable.
/// @dev Source-only flow: only the legs' source chains commit.
bytes1 constant ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY = 0x01;
/// @dev Accepted flow: every leg's destination chain must also accept it in time. See
/// {protocol-docs/atomicity/acceptance.md}.
bytes1 constant ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED = 0x02;

/// @dev The maximum number of legs in an atomic flow. Committing a leg is cheap (one IMT insert), but
/// finalizing ANY leg requires verifying one full inclusion proof — a settlement-layer Merkle proof
/// plus an IMT membership proof — per commitment of the flow, i.e. one per leg or two for an accepted
/// flow ({AtomicFlowManager.requireFlowFinalized}), so
/// an unbounded leg count would make destination-side execution arbitrarily expensive. The cap is
/// part of preimage validation ({AtomicFlowManager._validateAndComputeFlowId}), so an oversized flow
/// is rejected identically on the append, finalize and refund paths and can never commit a leg.
uint256 constant MAX_ATOMIC_FLOW_LEGS = 8;
