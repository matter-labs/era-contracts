// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// ── L2InteropCommitmentTree errors ───────────────────────────────────────────────────
// Value / low-nullifier validation now lives in {IndexedMerkleTree} and surfaces
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
/// @dev The per-leg source chain id array length does not equal the number of legs.
/// `legSourceChainIds` is aligned 1:1 with `legBundleHashes`; it may repeat and need not be ascending,
/// so only its length is checked.
error ManagerLegSourceChainIdsLengthMismatch(uint256 legs, uint256 chainIds);
/// @dev The number of inclusion proofs does not equal the number of legs.
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
/// @dev The bundle being executed on the destination is not one of the flow's legs.
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
/// @dev The reverted bundle has no recoverable calls, so there are no source funds to return.
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The claimed IMT root could not be proven as a chain-batch-root leaf of `(chainId, batchNumber)`
/// against the imported interop root.
error ProofImtRootInclusionFailed(uint256 chainId, uint256 batchNumber, bytes32 imtRoot);
/// @dev The leaf-to-chain-batch-root section of the proof is not exactly {ChainBatchRootTree.TREE_DEPTH}
/// hops. Pinning the depth guarantees the claimed value is a real batch-boundary IMT root leaf; a longer
/// path could descend into the IMT itself and pass off an internal node as "the root".
error ProofInvalidChainBatchRootDepth(uint256 expected, uint256 actual);
/// @dev The proof is a single-level / commit-based (final-node) proof, which carries no settlement-layer
/// block anchor. The atomic flow requires a multi-hop / SL-global proof so the deadline can be checked
/// against `pd.settlementLayerBatchNumber`.
error ProofMissingSettlementLayerAnchor(uint256 chainId, uint256 batchNumber);
/// @dev The batch's `l1Timestamp` is newer than the deadline (inclusion path).
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The batch's `l1Timestamp` is not strictly after the deadline (timeout-absence path: an in-time
/// batch's begin root says nothing about the deadline moment).
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
