// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// 0x742d1b5b
error CommitmentTreeNotAppender(address sender);
// 0x6bbd3c7c
error InteropCommitmentLeafHookFailed();
// 0x00bf0e3a
error ManagerAlreadyInitialized();
// 0xeff05b36
error ManagerBundleHashesNotSorted();
// 0xca272942
error ManagerCommittedBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0xbd57b2b9
error ManagerCommittedLegSourceChainMismatch(bytes32 flowId, uint256 thisChainId, uint256 declaredSourceChainId);
// 0x6a8bdfa0
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0xf8585117
error ManagerFlowIdMismatch(bytes32 expected, bytes32 computed);
// 0x1f6b4d47
error ManagerFlowPreimageVersionMismatch(bytes1 expected, bytes1 actual);
// 0x3a62d7e3
error ManagerLegAlreadyCommitted(bytes32 flowId, bytes32 bundleHash);
// 0x83562707
error ManagerLegNotRevertable(bytes32 flowId, bytes32 bundleHash, LegState actual);
// 0xe1a77fd3
error ManagerLegSourceChainIdsLengthMismatch(uint256 legs, uint256 chainIds);
// 0x62c42f1d
error ManagerLegSourceChainNotRegistered(uint256 legSourceChainId);
// 0x1f1f5965
error ManagerNoRecoverableCalls(bytes32 flowId, bytes32 bundleHash);
// 0xd7522d7a
error ManagerNotInteropCenter(address sender);
// 0x07029ea6
error ManagerNotInteropHandler(address sender);
// 0x87fcf6d9
error ManagerProofCountMismatch(uint256 legs, uint256 proofs);
// 0xbf1e3a23
error ManagerSettlementLayerNotL1(uint256 expectedL1ChainId, uint256 actual);
// 0x2911a778
error ProofDeadlineExceeded(uint256 batchTimestamp, uint64 deadline);
// 0x0aa51bc5
error ProofImtRootInclusionFailed(uint256 chainId, uint256 batchNumber, bytes32 imtRoot);
// 0x8839e86c
error ProofInclusionFailed(bytes32 root, uint256 value);
// 0xc04eb5fb
error ProofInteropRootNotAfterDeadline(uint256 rootTimestamp, uint64 deadline);
// 0x10657590
error ProofInvalidChainBatchRootDepth(uint256 expected, uint256 actual);
// 0x06a2d6b0
error ProofMissingSettlementLayerBatch(uint256 chainId, uint256 batchNumber);
// 0x691e9240
error ProofNonInclusionFailed(bytes32 root, uint256 value);
// 0x1ef4c1f6
error ProofNotLastBatchInRoot(uint256 level, bytes32 sibling);
// 0x9a462701
error ProofSettlementLayerInteropRootNotImported(uint256 slChainId, uint256 slBlock);
// 0x590cae72
error ProofSettlementLayerMismatch(uint256 expectedSlChainId, uint256 proofSlChainId);
// 0x75b23b57
error ProofSourceChainMismatch(uint256 expectedSourceChainId, uint256 proofSourceChainId);
// 0x81dbd1c1
error ProofTimeoutBranchMismatch(bool provesAgainstBeginRoot, uint256 l1BatchTimestamp, uint256 deadline);
