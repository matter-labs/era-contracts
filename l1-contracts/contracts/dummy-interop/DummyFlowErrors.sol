// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// ── L1FlowLinker errors ─────────────────────────────────────────────────────────────
error FlowAlreadyRegistered(bytes32 flowId);
error FlowNotInitiated(bytes32 flowId);
error FlowNotFinalized(bytes32 flowId);
error FlowExpired(bytes32 flowId);
error FlowNotExpired(bytes32 flowId, uint64 deadline);
error DeadlineInPast(uint64 deadline);
error EmptyParticipantSet();
error DuplicateParticipantChain(uint256 chainId);
error CommitCountMismatch(uint256 expected, uint256 actual);
error CommitChainNotInParticipants(uint256 chainId);
error CommitLogNotIncluded(uint256 chainId);
error CommitLogSenderMismatch(uint256 chainId, address expected, address actual);
error CommitLogTagMismatch(bytes4 actual);
error CommitLogFlowIdMismatch(bytes32 actual);
error DuplicateCommit(uint256 chainId);
error DestChainNotInParticipants(uint256 destChainId);
error MintValueSumMismatch(uint256 expected, uint256 actual);

// ── L2FlowEscrow errors ─────────────────────────────────────────────────────────────
error EscrowFlowAlreadyCommitted(bytes32 flowId);
error EscrowFlowNotCommitted(bytes32 flowId);
error EscrowFlowAlreadySettled(bytes32 flowId);
error EscrowSendSpecMissingDest();
error EscrowSendSpecZeroAmount();
error EscrowSendSpecZeroRecipient();
error EscrowSendSpecZeroToken();
error EscrowSendSpecSelfDest(uint256 destChainId);
error EscrowOnlyAliasedLinker(address sender);
error EscrowFollowupFailed(address target, bytes data);
error EscrowAlreadyInitialized();
