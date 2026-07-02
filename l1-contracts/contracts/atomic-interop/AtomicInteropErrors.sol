// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// ── L2InteropCommitmentTree errors ───────────────────────────────────────────────────
// Value / low-nullifier validation lives in {IndexedMerkleTree} and raises its own `IMT*` errors;
// only the appender access-control error remains here.
/// @dev `insert` is restricted to the {AtomicFlowManager}.
error CommitmentTreeNotAppender(address sender);

// ── AtomicFlowManager errors ─────────────────────────────────────────────────────────
/// @dev `append` is restricted to the {InteropCenter}.
error ManagerNotInteropCenter(address sender);
/// @dev `requireFlowFinalized` is restricted to the {InteropHandler}.
error ManagerNotInteropHandler(address sender);
/// @dev A `(flowId, bundleHash)` source leg was already committed on this chain.
error ManagerLegAlreadyCommitted(bytes32 flowId, bytes32 bundleHash);
/// @dev `claimRefund` was called for a leg not in the `Revertable` state.
error ManagerLegNotRevertable(bytes32 flowId, bytes32 bundleHash, LegState actual);
/// @dev The recomputed `flowId` does not match the one supplied.
error ManagerFlowIdMismatch(bytes32 expected, bytes32 computed);
/// @dev The supplied per-leg bundle hashes are not strictly ascending.
error ManagerBundleHashesNotSorted();
/// @dev The per-leg source chain id array length does not equal the number of legs.
/// `legSourceChainIds` is aligned 1:1 with `legBundleHashes`; it may repeat and need not be ascending,
/// so only its length is checked.
error ManagerLegSourceChainIdsLengthMismatch(uint256 legs, uint256 chainIds);
/// @dev The number of inclusion proofs does not equal the number of legs.
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
/// @dev The bundle being executed on the destination is not one of the flow's legs.
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
/// @dev The reverted bundle carries no calls at all (nothing to recover).
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);
/// @dev A fund-moving bundle call could not be recovered on the timeout path. Every call must be
/// recovered (send-time only commits recoverable asset-router calls); otherwise funds would be
/// stranded while the leg becomes terminally `Reverted`.
error ManagerCallNotRecovered(bytes32 flowId, bytes32 bundleHash, uint256 callIndex);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The commitment tree's `(root)` message could not be proven against the imported interop root
/// for `(chainId, batchNumber)`.
error ProofRootMessageInclusionFailed(uint256 chainId, uint256 batchNumber);
/// @dev The proof is a single-level commit-based proof with no settlement-layer anchor. The atomic flow
/// needs a multi-hop proof so the deadline can be checked against `pd.settlementLayerBatchNumber`.
error ProofMissingSettlementLayerAnchor(uint256 chainId, uint256 batchNumber);
/// @dev The batch's `l1Timestamp` is newer than the deadline (inclusion / absence-batch path).
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The batch's `l1Timestamp` is not strictly after the deadline (adjacency-successor path).
error ProofDeadlineNotExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The commit value is not a member of the authenticated root.
error ProofInclusionFailed(bytes32 root, uint256 value);
/// @dev The low-nullifier does not certify absence of the commit value in the authenticated root.
error ProofNonInclusionFailed(bytes32 root, uint256 value);
/// @dev A proof's `sourceChainId` does not match the leg's declared source chain. Binding these prevents
/// a non-inclusion proof against an unrelated chain (where the commit value is trivially absent) from
/// force-refunding an on-time, finalized leg, which would double-mint.
error ProofSourceChainMismatch(uint256 expectedSourceChainId, uint256 proofSourceChainId);
/// @dev A proof's resolved settlement-layer chain id does not match the flow's `settlementLayerChainId`.
/// Legs settling on different settlement layers have incomparable deadline/timestamp scales, so rejecting
/// them keeps the single-`deadline` comparison well-defined.
error ProofSettlementLayerMismatch(uint256 expectedSlChainId, uint256 proofSlChainId);
/// @dev The timeout's adjacency witness is not the consecutive successor of the absence batch
/// (`successorBatchNumber != absenceBatchNumber + 1`). The witness must be batch N+1 so it pins N as the
/// last batch with `l1Timestamp <= deadline`.
error ProofAdjacencyNotConsecutive(uint256 absenceBatchNumber, uint256 successorBatchNumber);
