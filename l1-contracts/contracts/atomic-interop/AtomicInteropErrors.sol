// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// ── L2InteropCommitmentTree errors ───────────────────────────────────────────────────
// Value / low-nullifier validation now lives in {IndexedMerkleTree} (the IMT engine) and surfaces
// its own `IMT*` errors; only the shell's appender ACL error remains here.
/// @dev `insert` is restricted to the canonical {AtomicFlowManager}.
error CommitmentTreeNotAppender(address sender);

// ── AtomicFlowManager errors ─────────────────────────────────────────────────────────
/// @dev `append` is restricted to the canonical {InteropCenter}.
error ManagerNotInteropCenter(address sender);
/// @dev `requireFlowFinalized` is restricted to the canonical {InteropHandler}.
error ManagerNotInteropHandler(address sender);
/// @dev A `(flowId, bundleHash)` source leg was already committed on this chain.
error ManagerLegAlreadyCommitted(bytes32 flowId, bytes32 bundleHash);
/// @dev `claimRefund` was called for a leg not in the `Revertable` state.
error ManagerLegNotRevertable(bytes32 flowId, bytes32 bundleHash, LegState actual);
/// @dev The recomputed `flowId` does not match the one supplied.
error ManagerFlowIdMismatch(bytes32 expected, bytes32 computed);
/// @dev The supplied per-leg bundle hashes are not strictly ascending.
error ManagerBundleHashesNotSorted();
/// @dev The positional per-leg source chain id array length does not equal the number of legs.
/// `legSourceChainIds` is aligned 1:1 with `legBundleHashes` (it may repeat and need not be ascending),
/// so only its length is constrained.
error ManagerLegSourceChainIdsLengthMismatch(uint256 legs, uint256 chainIds);
/// @dev The number of inclusion proofs does not equal the number of legs.
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
/// @dev The bundle being executed on the destination is not one of the flow's legs.
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
/// @dev The reverted bundle carries no calls at all (nothing to recover).
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);
/// @dev A fund-moving bundle call could not be recovered on the timeout path. Every call MUST be
/// recovered (the send-time gate only commits recoverable asset-router calls), so a non-recovered
/// call would otherwise silently strand funds while the leg becomes terminally `Reverted`.
error ManagerCallNotRecovered(bytes32 flowId, bytes32 bundleHash, uint256 callIndex);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The commitment tree's `(root)` message could not be proven against the imported interop root
/// for `(chainId, batchNumber)`.
error ProofRootMessageInclusionFailed(uint256 chainId, uint256 batchNumber);
/// @dev The proof is a single-level / commit-based (final-node) proof, which carries no settlement-layer
/// block anchor. The atomic flow requires a multi-hop / SL-global proof so the deadline can be checked
/// against `pd.settlementLayerBatchNumber`.
error ProofMissingSettlementLayerAnchor(uint256 chainId, uint256 batchNumber);
/// @dev The batch's settlement timestamp is newer than the deadline (inclusion / absence-batch path).
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The batch's settlement timestamp is not strictly after the deadline (adjacency-successor path).
error ProofDeadlineNotExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The commit value is not a member of the authenticated root.
error ProofInclusionFailed(bytes32 root, uint256 value);
/// @dev The low-nullifier does not certify absence of the commit value in the authenticated root.
error ProofNonInclusionFailed(bytes32 root, uint256 value);
/// @dev BIND-CHAIN: a proof's `sourceChainId` does not match the leg's declared source chain.
/// Without this binding, a non-inclusion proof can be made against any unrelated chain (where the leg's
/// commit value is trivially absent), force-refunding an on-time, finalized leg -> double-mint.
error ProofSourceChainMismatch(uint256 expectedSourceChainId, uint256 proofSourceChainId);
/// @dev BIND-SL: a proof's resolved settlement-layer chain id does not match the flow's declared
/// `settlementLayerChainId`. Legs settling on different SLs have incomparable `deadline`/timestamp scales;
/// rejecting them keeps the single-`deadline` comparison well-defined.
error ProofSettlementLayerMismatch(uint256 expectedSlChainId, uint256 proofSlChainId);
/// @dev RULE-ADJACENCY: the timeout's adjacency witness is not the consecutive successor of the
/// absence batch (`successorBatchNumber != absenceBatchNumber + 1`). The witness MUST be batch N+1 so it
/// pins N as the LAST batch with settlement timestamp `t <= deadline`.
error ProofAdjacencyNotConsecutive(uint256 absenceBatchNumber, uint256 successorBatchNumber);
