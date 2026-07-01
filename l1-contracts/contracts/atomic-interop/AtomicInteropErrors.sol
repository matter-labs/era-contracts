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
/// @dev The supplied participant chain ids are not strictly ascending.
error ManagerChainsNotSorted();
/// @dev The number of inclusion proofs does not equal the number of legs.
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
/// @dev The bundle being executed on the destination is not one of the flow's legs.
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
/// @dev The reverted bundle carries no recoverable asset-router calls.
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The commitment tree's `(root)` message could not be proven against the imported interop root
/// for `(chainId, batchNumber)`.
error ProofRootMessageInclusionFailed(uint256 chainId, uint256 batchNumber);
/// @dev The proof is a single-level / commit-based (final-node) proof, which carries no settlement-layer
/// block anchor. The atomic flow requires a multi-hop / SL-global proof so the deadline can be checked
/// against `pd.settlementLayerBatchNumber`.
error ProofMissingSettlementLayerAnchor(uint256 chainId, uint256 batchNumber);
/// @dev The authenticated root's settlement-layer block number is newer than the deadline (inclusion path).
error ProofDeadlineExceeded(uint256 slBlock, uint64 deadline);
/// @dev The authenticated root's settlement-layer block number is not strictly after the deadline
/// (non-inclusion path).
error ProofDeadlineNotExceeded(uint256 slBlock, uint64 deadline);
/// @dev The commit value is not a member of the authenticated root.
error ProofInclusionFailed(bytes32 root, uint256 value);
/// @dev The low-nullifier does not certify absence of the commit value in the authenticated root.
error ProofNonInclusionFailed(bytes32 root, uint256 value);
