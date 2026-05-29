// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SpecState} from "./IDummyFlow.sol";

// ── L1FlowLinker errors ─────────────────────────────────────────────────────────────
error LinkerNotInitialized();
error LinkerAlreadyInitialized();
error FlowAlreadyRegistered(bytes32 flowId);
error FlowNotInitiated(bytes32 flowId);
error FlowNotFinalized(bytes32 flowId);
error FlowExpired(bytes32 flowId);
error FlowNotExpired(bytes32 flowId, uint64 deadline);
error DeadlineInPast(uint64 deadline);
error EmptyParticipantSet();
error DuplicateParticipantChain(uint256 chainId);
error ChainsNotSorted();
error CommitLogNotIncluded(uint256 chainId);
error CommitLogSenderMismatch(uint256 chainId, address actual);
error CommitLogTagMismatch(bytes4 actual);
error CommitLogFlowIdMismatch(bytes32 actual);
error DuplicateCommit(bytes32 specHash);
error FlowIdMismatch(bytes32 expected, bytes32 actual);
error CommitChainNotInParticipants(uint256 chainId);
error DestChainNotInParticipants(uint256 destChainId);
error MintValueSumMismatch(uint256 expected, uint256 actual);
error ExecParamsLengthMismatch(uint256 expected, uint256 actual);
error LinkerInitEscrowLenMismatch(uint256 chainIdsLen, uint256 escrowsLen);
error LinkerInitEmptyChainIds();
error LinkerInitZeroEscrow(uint256 chainId);
error LinkerEscrowNotRegistered(uint256 chainId);

// ── L2FlowEscrow errors ─────────────────────────────────────────────────────────────
error EscrowAlreadyInitialized();
error EscrowDepositorMismatch(address sender, address depositor);
error EscrowSpecAlreadyCommitted(bytes32 specHash);
error EscrowSpecNotExecutable(bytes32 specHash, SpecState actual);
error EscrowSpecNotRevertable(bytes32 specHash, SpecState actual);
error EscrowInvalidAuthorizeFromState(bytes32 specHash, SpecState actual);
error EscrowInvalidRefundAuthorizeFromState(bytes32 specHash, SpecState actual);
error EscrowOnlyAliasedLinker(address sender);
error EscrowSpecNotForThisChain(uint256 originChainId, uint256 destChainId);
error EscrowSendSpecMissingDest();
error EscrowSendSpecZeroAmount();
error EscrowSendSpecZeroRecipient();
error EscrowSendSpecZeroToken();
error EscrowSendSpecZeroOriginChain();
error EscrowSelfDestination(uint256 destChainId);
