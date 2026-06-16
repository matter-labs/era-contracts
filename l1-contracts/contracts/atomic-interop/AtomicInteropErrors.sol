// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SpecState} from "./IAtomicInterop.sol";

// ── L2InteropCommitmentTree errors ───────────────────────────────────────────────────
// Value / low-nullifier validation now lives in {IndexedMerkleTreeLib} (the IMT engine) and surfaces
// its own `IMT*` errors; only the shell's ACL / init errors remain here.
error CommitmentTreeAlreadyInitialized();
error CommitmentTreeNotAppender(address sender);
error CommitmentTreeZeroAppender();

// ── AtomicFlowEscrow errors ──────────────────────────────────────────────────────────
error EscrowAlreadyInitialized();
error EscrowDepositorMismatch(address sender, address depositor);
error EscrowSpecAlreadyCommitted(bytes32 specHash);
error EscrowSpecNotExecutable(bytes32 specHash, SpecState actual);
error EscrowSpecNotRevertable(bytes32 specHash, SpecState actual);
error EscrowInvalidAuthorizeFromState(bytes32 specHash, SpecState actual);
error EscrowInvalidRefundAuthorizeFromState(bytes32 specHash, SpecState actual);
error EscrowSpecNotForThisChain(uint256 originChainId, uint256 destChainId);
error EscrowSendSpecMissingDest();
error EscrowSendSpecZeroAmount();
error EscrowSendSpecZeroRecipient();
error EscrowSendSpecZeroToken();
error EscrowSendSpecZeroOriginChain();
error EscrowSelfDestination(uint256 destChainId);
error EscrowFlowIdMismatch(bytes32 expected, bytes32 actual);
error EscrowProofCountMismatch(uint256 specs, uint256 proofs);
error EscrowSpecsNotSorted();
error EscrowChainsNotSorted();
/// @dev A spec originating on this chain was not committed here, yet no inclusion proof was supplied.
error EscrowSpecNotCommittedLocally(bytes32 specHash, SpecState actual);
/// @dev A spec originating on another chain has no inclusion proof.
error EscrowMissingProof(bytes32 specHash);

// ── AtomicInteropProof library errors ────────────────────────────────────────────────
/// @dev The proof's `sourceChainId` does not match the spec's origin chain.
error ProofChainMismatch(uint256 expected, uint256 actual);
/// @dev The commitment tree's `(root, timestamp)` message could not be proven against the imported
/// interop root for `(chainId, batchNumber)`.
error ProofRootMessageInclusionFailed(uint256 chainId, uint256 batchNumber);
/// @dev The authenticated root snapshot is newer than the deadline (inclusion path).
error ProofDeadlineExceeded(uint256 timestamp, uint64 deadline);
/// @dev The authenticated root snapshot is not strictly after the deadline (non-inclusion path).
error ProofDeadlineNotExceeded(uint256 timestamp, uint64 deadline);
/// @dev The commit value is not a member of the authenticated root.
error ProofInclusionFailed(bytes32 root, uint256 value);
/// @dev The low-nullifier does not certify absence of the commit value in the authenticated root.
error ProofNonInclusionFailed(bytes32 root, uint256 value);
