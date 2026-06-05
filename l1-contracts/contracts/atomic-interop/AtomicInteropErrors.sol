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

// ── L2InteropCommitmentTree errors ──────────────────────────────────────────────────
error CommitmentTreeAlreadyInitialized();
error CommitmentTreeNotAppender(address sender);
error CommitmentTreeZeroAppender();

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
error ProofRootChangedAcrossDeadline(bytes32 rootBefore, bytes32 rootAfter);
error ProofLeafPresent(bytes32 leaf);
error ProofNonInclusionRecomputeFailed(bytes32 expectedRoot, bytes32 computedRoot);
