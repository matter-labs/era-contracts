// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SpecState} from "./IAtomicInterop.sol";

// ── GlobalInteropIMT (L1) errors ────────────────────────────────────────────────────
error GlobalImtZeroBridgehub();
/// @dev The caller is neither the chain's diamond proxy (from the Bridgehub) nor a global submitter.
error GlobalImtNotSubmitter(address sender, uint256 chainId);
/// @dev Only the owner may manage the temporary global-submitter stub.
error GlobalImtNotOwner(address sender);
error GlobalImtZeroSubmitter();
error GlobalImtZeroRoot();
/// @dev Batch numbers must be strictly consecutive (no gaps).
error GlobalImtNonConsecutiveBatch(uint256 chainId, uint256 expected, uint256 provided);
error GlobalImtUnknownBlock(uint256 blockNumber);

// ── L2InteropCommitmentTree (indexed merkle tree) errors ─────────────────────────────
error CommitmentTreeAlreadyInitialized();
error CommitmentTreeNotAppender(address sender);
error CommitmentTreeZeroAppender();
error CommitmentTreeZeroValue();
/// @dev The supplied low-nullifier's value is not strictly below the value being inserted.
error CommitmentTreeLowNullifierNotBelow(uint256 value, uint256 lowValue);
/// @dev The value being inserted is not strictly below the low-nullifier's nextValue (already present or wrong nullifier).
error CommitmentTreeLowNullifierNotAbove(uint256 value, uint256 nextValue);

// ── L2GlobalInteropRootImporter errors ──────────────────────────────────────────────
error ImporterAlreadyInitialized();
error ImporterNotSupplier(address sender);
error ImporterZeroSupplier();
error ImporterZeroRoot();
error ImporterRootAlreadyImported(uint256 l1BlockNumber);
error ImporterRootMismatch(uint256 l1BlockNumber, bytes32 stored, bytes32 provided);
error ImporterBlockNotImported(uint256 l1BlockNumber);

// ── AtomicFlowEscrow errors ─────────────────────────────────────────────────────────
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

// ── AtomicInteropProof library errors ───────────────────────────────────────────────
error ProofChainMismatch(uint256 expected, uint256 actual);
error ProofInclusionFailed(bytes32 expectedRoot, bytes32 computedRoot);
error ProofGlobalInclusionFailed(bytes32 expectedRoot, bytes32 computedRoot);
error ProofDeadlineExceeded(uint256 timestamp, uint64 deadline);
error ProofDeadlineNotExceeded(uint256 timestamp, uint64 deadline);
/// @dev The included leaf's value does not equal the commit value being proven.
error ProofValueMismatch(uint256 expected, uint256 actual);
/// @dev The low-nullifier leaf's value is not strictly below the target (so it cannot certify absence).
error ProofLowNullifierNotBelow(uint256 value, uint256 lowValue);
/// @dev The target value is not strictly below the low-nullifier's `nextValue` (so the target could be present).
error ProofLowNullifierNotAbove(uint256 value, uint256 nextValue);
