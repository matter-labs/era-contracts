// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// Errors raised while verifying atomic-interop message inclusion / timeout proofs ({AtomicInteropProof}).

// 0x7e2eeccd
error AtomicDeadlineExceeded(uint256 slBlock, uint256 deadline);
// 0x78535715
error AtomicDeadlineNotExceeded(uint256 slBlock, uint256 deadline);
// 0x51638a9d
error AtomicInclusionFailed(bytes32 imtRoot, uint256 commitValue);
// 0x61d9dccd
error AtomicMissingSettlementLayerAnchor(uint256 chainId, uint256 batchNumber);
// 0x806d5f1a
error AtomicNonInclusionFailed(bytes32 imtRoot, uint256 commitValue);
// 0xbb167ccc
error AtomicProofChainMismatch(uint256 expectedChainId, uint256 actualChainId);
// 0xe8d56e17
error AtomicRootMessageInclusionFailed(uint256 chainId, uint256 batchNumber);
