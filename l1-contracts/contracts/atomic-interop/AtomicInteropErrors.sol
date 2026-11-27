// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LegState} from "./IAtomicInterop.sol";

// 0x742d1b5b
error CommitmentTreeNotAppender(address sender);
// 0x6bbd3c7c
error InteropCommitmentLeafHookFailed();
// 0x1defdb80
error ManagerAbsenceChainNotInLeg(bytes32 flowId, uint256 legIndex, uint256 absenceChainId);
// 0xf30c75fb
error ManagerAcceptedLegDestinationChainMismatch(
    bytes32 flowId,
    uint256 thisChainId,
    uint256 declaredDestinationChainId
);
// 0x19dd7658
error ManagerAcceptedLegSourceChainMismatch(bytes32 flowId, uint256 bundleSourceChainId, uint256 declaredSourceChainId);
// 0x00bf0e3a
error ManagerAlreadyInitialized();
// 0xeff05b36
error ManagerBundleHashesNotSorted();
// 0x03460b6a
error ManagerBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0xdff68473
error ManagerCommittedLegDestinationChainMismatch(
    bytes32 flowId,
    uint256 bundleDestinationChainId,
    uint256 declaredDestinationChainId
);
// 0xbd57b2b9
error ManagerCommittedLegSourceChainMismatch(bytes32 flowId, uint256 thisChainId, uint256 declaredSourceChainId);
// 0x6a8bdfa0
error ManagerExecutingBundleNotInFlow(bytes32 flowId, bytes32 bundleHash);
// 0x44906526
error ManagerFlowDeadlinePassed(uint64 deadline, uint256 latestImportedRootTimestamp);
// 0xf8585117
error ManagerFlowIdMismatch(bytes32 expected, bytes32 computed);
// 0x1f6b4d47
error ManagerFlowPreimageVersionMismatch(bytes1 expected, bytes1 actual);
// 0xb5e6e3fc
error ManagerL1ChainIdZero();
// 0xb2e8cabb
error ManagerLegAlreadyRecorded(bytes32 flowId, bytes32 bundleHash, LegState actual);
// 0xe0ec98f5
error ManagerLegChainIdsLengthMismatch(uint256 expected, uint256 actual);
// 0xa8978a1f
error ManagerLegChainNotAllowed(uint256 legChainId);
// 0x0060a508
error ManagerLegDestinationChainIdsLengthMismatch(uint256 expected, uint256 actual);
// 0x923d52e0
error ManagerLegFromChainToItself(uint256 legIndex, uint256 chainId);
// 0x83562707
error ManagerLegNotRevertable(bytes32 flowId, bytes32 bundleHash, LegState actual);
// 0x4dbe1536
error ManagerMissingLegIndexOutOfRange(uint256 legs, uint256 missingLegIndex);
// 0xd7522d7a
error ManagerNotInteropCenter(address sender);
// 0x07029ea6
error ManagerNotInteropHandler(address sender);
// 0x87fcf6d9
error ManagerProofCountMismatch(uint256 expected, uint256 proofs);
// 0xbf1e3a23
error ManagerSettlementLayerNotL1(uint256 expectedL1ChainId, uint256 actual);
// 0x9f73095b
error ManagerTooManyLegs(uint256 maxLegs, uint256 legs);
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
