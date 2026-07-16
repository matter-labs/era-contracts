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

/// @dev The flow declares a settlement layer other than L1; in this release interop legs settle on
/// L1 only.
error ManagerSettlementLayerNotL1(uint256 expectedL1ChainId, uint256 actual);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The claimed IMT root could not be proven as a chain-batch-root leaf of `(chainId, batchNumber)`
/// against the imported interop root.
error ProofImtRootInclusionFailed(uint256 chainId, uint256 batchNumber, bytes32 imtRoot);
/// @dev The leaf-to-chain-batch-root section of the proof is not exactly {ChainBatchRootTree.TREE_DEPTH}
/// hops. Pinning the depth guarantees the claimed value is a real batch-boundary IMT root leaf; a longer
/// path could descend into the IMT itself and pass off an internal node as "the root".
error IMTProofInvalidChainBatchRootDepth(uint256 expected, uint256 actual);
/// @dev The proof is a single-level / commit-based (final-node) proof, which carries no
/// settlement-layer batch reference. The atomic flow requires a multi-hop / SL-global proof so the
/// deadline can be checked against `pd.settlementLayerBatchNumber`.
error ProofMissingSettlementLayerBatch(uint256 chainId, uint256 batchNumber);
/// @dev The batch's `l1Timestamp` is newer than the deadline (inclusion path; a batch with
/// `t > deadline` is late).
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
/// @dev The aggregated root the timeout proof resolves against was not created strictly after the
/// deadline (the timestamp in `interopRoots[slChainId][slBlock]` is `<= deadline`; an unset entry
/// reads as 0 and is rejected too).
error ProofInteropRootNotAfterDeadline(uint256 rootTimestamp, uint64 deadline);

/// @dev No interop root was ever imported for the settlement-layer block the proof resolves against.
error ProofSettlementLayerInteropRootNotImported(uint256 slChainId, uint256 slBlock);
/// @dev The batch used for the in-time (`t <= deadline`) branch of the timeout proof is not the source
/// chain's last batch inside the aggregated root: the batch-leaf Merkle path has a populated right
/// sibling at `level` where the empty-subtree hash was required.
error ProofNotLastBatchInRoot(uint256 level, bytes32 sibling);

/// @dev The prover-declared timeout branch does not match the authenticated batch inclusion time:
/// the begin-root branch requires a late batch (`l1BatchTimestamp > deadline`), the end-root branch
/// an in-time one (`l1BatchTimestamp <= deadline`).
error ProofTimeoutBranchMismatch(bool provesAgainstBeginRoot, uint256 l1BatchTimestamp, uint256 deadline);
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
