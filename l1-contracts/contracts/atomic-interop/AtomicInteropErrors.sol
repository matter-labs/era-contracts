// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PartState} from "./IAtomicInterop.sol";

// ── GlobalInteropIMT (L1) errors ────────────────────────────────────────────────────
error GlobalImtZeroOwner();
error GlobalImtNotOwner(address sender);
error GlobalImtNotSubmitter(address sender, uint256 chainId);
error GlobalImtZeroRoot();
error GlobalImtZeroSubmitter();
error GlobalImtBatchNotIncreasing(uint256 chainId, uint256 current, uint256 provided);
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
error EscrowLegNotOnThisChain(uint256 legChainId);
error EscrowLegZeroAmount();
error EscrowLegZeroToken();
error EscrowLegZeroPayer();
error EscrowLegZeroPayee();
error EscrowPayerMismatch(address sender, address payer);
error EscrowPartNotUnset(bytes32 specHash, PartState actual);
error EscrowPartNotCommitted(bytes32 specHash, PartState actual);
error EscrowFlowIdMismatch(bytes32 expected, bytes32 actual);
error EscrowProofCountMismatch(uint256 legs, uint256 proofs);
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
