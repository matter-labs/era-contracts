// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// 0x742d1b5b
/// @notice `insert` called by an account other than the canonical {AtomicFlowManager}.
error CommitmentTreeNotAppender(address sender);
// 0x00bf0e3a
/// @notice `initL2` called on an already-initialized manager.
error ManagerAlreadyInitialized();
// 0xeff05b36
/// @notice The flow preimage's `legBundleHashes` are not strictly ascending.
error ManagerBundleHashesNotSorted();
// 0xca272942
/// @notice The bundle being committed is not one of the flow's legs.
error ManagerCommittedBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0xbd57b2b9
/// @notice The committing leg's declared source chain is not this chain.
error ManagerCommittedLegSourceChainMismatch(bytes32 flowId, uint256 thisChainId, uint256 declaredSourceChainId);
// 0x6a8bdfa0
/// @notice The bundle being executed on the destination is not one of the flow's legs.
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0xf8585117
/// @notice The `flowId` recomputed from the preimage does not match the supplied one.
error ManagerFlowIdMismatch(bytes32 expected, bytes32 computed);
// 0x3a62d7e3
/// @notice The `(flowId, bundleHash)` source leg was already committed on this chain.
error ManagerLegAlreadyCommitted(bytes32 flowId, bytes32 bundleHash);
// 0x83562707
/// @notice `claimRefund` called for a leg not in the `Revertable` state.
error ManagerLegNotRevertable(bytes32 flowId, bytes32 bundleHash, LegState actual);
// 0xe1a77fd3
/// @notice The `legSourceChainIds` array length does not equal the number of legs.
error ManagerLegSourceChainIdsLengthMismatch(uint256 legs, uint256 chainIds);
// 0x62c42f1d
/// @notice A leg declares a source chain that is not registered as an interop chain.
error ManagerLegSourceChainNotRegistered(uint256 legSourceChainId);
// 0x1f1f5965
/// @notice The refunded bundle recovered no calls, so there are no source funds to return.
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);
// 0xd7522d7a
/// @notice `append` called by an account other than the {InteropCenter}.
error ManagerNotInteropCenter(address sender);
// 0x07029ea6
/// @notice `requireFlowFinalized` called by an account other than the {InteropHandler}.
error ManagerNotInteropHandler(address sender);
// 0x87fcf6d9
/// @notice The number of finality proofs does not equal the number of legs.
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
// 0xbf1e3a23
/// @notice The flow declares a settlement layer other than L1.
error ManagerSettlementLayerNotL1(uint256 expectedL1ChainId, uint256 actual);
// 0x2911a778
/// @notice The inclusion proof's batch settled after the flow deadline.
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
// 0x0aa51bc5
/// @notice The claimed IMT root could not be proven as a chain-batch-root leaf of `(chainId, batchNumber)`.
error ProofImtRootInclusionFailed(uint256 chainId, uint256 batchNumber, bytes32 imtRoot);
// 0x8839e86c
/// @notice The commit value is not a member of the authenticated IMT root.
error ProofInclusionFailed(bytes32 root, uint256 value);
// 0xc04eb5fb
/// @notice The timeout proof's interop root was not created strictly after the deadline.
error ProofInteropRootNotAfterDeadline(uint256 rootTimestamp, uint64 deadline);
// 0x10657590
/// @notice The leaf-to-chain-batch-root section of the proof is not exactly the pinned depth.
error ProofInvalidChainBatchRootDepth(uint256 expected, uint256 actual);
// 0x06a2d6b0
/// @notice The proof carries no settlement-layer batch reference (single-level proofs are not accepted).
error ProofMissingSettlementLayerBatch(uint256 chainId, uint256 batchNumber);
// 0x691e9240
/// @notice The low leaf does not certify absence of the commit value in the authenticated root.
error ProofNonInclusionFailed(bytes32 root, uint256 value);
// 0x1ef4c1f6
/// @notice The in-time timeout batch is not the source chain's last batch inside the interop root.
error ProofNotLastBatchInRoot(uint256 level, bytes32 sibling);
// 0x9a462701
/// @notice No interop root was imported for the settlement-layer block the proof resolves against.
error ProofSettlementLayerInteropRootNotImported(uint256 slChainId, uint256 slBlock);
// 0x590cae72
/// @notice The proof's resolved settlement-layer chain id does not match the flow's.
error ProofSettlementLayerMismatch(uint256 expectedSlChainId, uint256 proofSlChainId);
// 0x75b23b57
/// @notice The proof's `sourceChainId` does not match the leg's declared source chain.
error ProofSourceChainMismatch(uint256 expectedSourceChainId, uint256 proofSourceChainId);
// 0x81dbd1c1
/// @notice The declared timeout branch does not match the batch's authenticated inclusion time.
error ProofTimeoutBranchMismatch(bool provesAgainstBeginRoot, uint256 l1BatchTimestamp, uint256 deadline);
