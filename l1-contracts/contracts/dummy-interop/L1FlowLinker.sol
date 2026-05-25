// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL1FlowLinker, CommitProof, ExecuteParams} from "./IL1FlowLinker.sol";
import {COMMIT_LOG_TAG, FlowState, Participant, SendSpec} from "./IDummyFlow.sol";
import {IL2FlowEscrow} from "./IL2FlowEscrow.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestDirect} from "../core/bridgehub/IBridgehubBase.sol";
import {IMessageVerification} from "../common/interfaces/IMessageVerification.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {
    CommitChainNotInParticipants,
    CommitCountMismatch,
    CommitLogFlowIdMismatch,
    CommitLogNotIncluded,
    CommitLogSenderMismatch,
    CommitLogTagMismatch,
    DeadlineInPast,
    DestChainNotInParticipants,
    DuplicateCommit,
    DuplicateParticipantChain,
    EmptyParticipantSet,
    FlowAlreadyRegistered,
    FlowExpired,
    FlowNotExpired,
    FlowNotFinalized,
    FlowNotInitiated,
    MintValueSumMismatch
} from "./DummyFlowErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IL1FlowLinker`. Owns flow lifecycle on L1, verifies per-chain commit logs
/// against each chain's batch root, and drives finality by dispatching one L1→L2 priority tx
/// per participating chain via `Bridgehub.requestL2TransactionDirect`. ETH-base chains only
/// in this V1 — custom-base-token chains and Gateway-settled chains are out of scope.
contract L1FlowLinker is IL1FlowLinker, ReentrancyGuard {
    IL1Bridgehub public immutable BRIDGEHUB;
    IMessageVerification public immutable MESSAGE_VERIFICATION;

    struct Flow {
        FlowState state;
        uint64 deadline;
        address registrar;
    }

    mapping(bytes32 flowId => Flow) internal _flows;
    mapping(bytes32 flowId => uint256[]) internal _participantChains;
    /// @dev `escrow == address(0)` means "chainId not in this flow's participating set".
    mapping(bytes32 flowId => mapping(uint256 chainId => address escrow)) internal _participantEscrow;
    mapping(bytes32 flowId => mapping(uint256 chainId => SendSpec)) internal _commits;
    mapping(bytes32 flowId => mapping(uint256 chainId => bool)) internal _hasCommit;

    constructor(IL1Bridgehub _bridgehub, IMessageVerification _messageVerification) reentrancyGuardInitializer {
        BRIDGEHUB = _bridgehub;
        MESSAGE_VERIFICATION = _messageVerification;
    }

    /// @inheritdoc IL1FlowLinker
    function registerFlow(bytes32 _flowId, Participant[] calldata _participants, uint64 _deadline) external {
        if (_flows[_flowId].state != FlowState.None) revert FlowAlreadyRegistered(_flowId);
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);

        uint256 n = _participants.length;
        if (n == 0) revert EmptyParticipantSet();

        for (uint256 i; i < n; ++i) {
            Participant calldata p = _participants[i];
            if (_participantEscrow[_flowId][p.chainId] != address(0)) revert DuplicateParticipantChain(p.chainId);
            _participantEscrow[_flowId][p.chainId] = p.escrow;
            _participantChains[_flowId].push(p.chainId);
        }

        _flows[_flowId] = Flow({state: FlowState.Initiated, deadline: _deadline, registrar: msg.sender});
        emit FlowRegistered(_flowId, msg.sender, _deadline);
    }

    /// @inheritdoc IL1FlowLinker
    function recordFinalitySignal(bytes32 _flowId, CommitProof[] calldata _proofs) external nonReentrant {
        Flow storage flow = _flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp > flow.deadline) revert FlowExpired(_flowId);

        // Verify + ingest each commit log. We don't require every participant to commit —
        // receive-only chains never publish a commit log. Senders must.
        uint256 commitCount = _proofs.length;
        for (uint256 i; i < commitCount; ++i) {
            _ingestCommit(_flowId, _proofs[i]);
        }

        // Graph closure: every `destChainId` referenced by any commit must be in the
        // participating set. Receive-only chains were registered up-front in `registerFlow`,
        // so the check is just a lookup against `_participantEscrow`.
        uint256 chainsLen = _participantChains[_flowId].length;
        for (uint256 i; i < chainsLen; ++i) {
            uint256 chainId = _participantChains[_flowId][i];
            if (!_hasCommit[_flowId][chainId]) continue;
            uint256 dest = _commits[_flowId][chainId].destChainId;
            if (_participantEscrow[_flowId][dest] == address(0)) revert DestChainNotInParticipants(dest);
        }

        flow.state = FlowState.Finalized;
        emit FlowFinalized(_flowId);
    }

    /// @dev Verify a single commit log against `MESSAGE_VERIFICATION` and store its `SendSpec`.
    /// Reverts on tag/sender/flowId mismatch, duplicate commit, or chain not in the
    /// participating set. The verification check itself is what binds the SendSpec to an
    /// actual L2 inclusion — without it, anyone could craft an arbitrary commit log.
    function _ingestCommit(bytes32 _flowId, CommitProof calldata _proof) internal {
        address expectedEscrow = _participantEscrow[_flowId][_proof.chainId];
        if (expectedEscrow == address(0)) revert CommitChainNotInParticipants(_proof.chainId);
        if (_proof.message.sender != expectedEscrow) {
            revert CommitLogSenderMismatch(_proof.chainId, expectedEscrow, _proof.message.sender);
        }
        if (_hasCommit[_flowId][_proof.chainId]) revert DuplicateCommit(_proof.chainId);

        bool included = MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _proof.chainId,
            _blockOrBatchNumber: _proof.blockOrBatchNumber,
            _index: _proof.messageIndex,
            _message: _proof.message,
            _proof: _proof.merkleProof
        });
        if (!included) revert CommitLogNotIncluded(_proof.chainId);

        (bytes4 tag, bytes32 logFlowId, address logEscrow, SendSpec memory spec) = abi.decode(
            _proof.message.data,
            (bytes4, bytes32, address, SendSpec)
        );
        if (tag != COMMIT_LOG_TAG) revert CommitLogTagMismatch(tag);
        if (logFlowId != _flowId) revert CommitLogFlowIdMismatch(logFlowId);
        // Belt-and-braces: the message.sender check already pins the escrow, but the
        // payload also self-identifies and we cross-check for safety.
        if (logEscrow != expectedEscrow) {
            revert CommitLogSenderMismatch(_proof.chainId, expectedEscrow, logEscrow);
        }

        _hasCommit[_flowId][_proof.chainId] = true;
        SendSpec storage stored = _commits[_flowId][_proof.chainId];
        stored.destChainId = spec.destChainId;
        stored.recipient = spec.recipient;
        stored.token = spec.token;
        stored.amount = spec.amount;
        stored.followupTo = spec.followupTo;
        stored.followupData = spec.followupData;
    }

    /// @inheritdoc IL1FlowLinker
    function executeFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable nonReentrant {
        if (_flows[_flowId].state != FlowState.Finalized) revert FlowNotFinalized(_flowId);
        _checkExecParamsLen(_flowId, _execParams);

        uint256[] storage chains = _participantChains[_flowId];
        uint256 chainsLen = chains.length;
        for (uint256 i; i < chainsLen; ++i) {
            _dispatchExecuteOne(_flowId, chains[i], _execParams[i]);
        }
    }

    /// @inheritdoc IL1FlowLinker
    function revertFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable nonReentrant {
        Flow storage flow = _flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp <= flow.deadline) revert FlowNotExpired(_flowId, flow.deadline);

        _checkExecParamsLen(_flowId, _execParams);

        flow.state = FlowState.Reverted;
        emit FlowReverted(_flowId);

        uint256[] storage chains = _participantChains[_flowId];
        uint256 chainsLen = chains.length;
        bytes memory calldataPayload = abi.encodeCall(IL2FlowEscrow.refundFromL1, (_flowId));
        for (uint256 i; i < chainsLen; ++i) {
            _dispatchRefundOne(_flowId, chains[i], _execParams[i], calldataPayload);
        }
    }

    /// @dev Validates `_execParams.length` matches the participating set size and that
    /// `msg.value` equals the sum of per-chain `mintValue`s. ETH-base chains only — a
    /// custom-base-token destination would require pre-approving the AssetRouter (deferred).
    function _checkExecParamsLen(bytes32 _flowId, ExecuteParams[] calldata _execParams) internal view {
        uint256 chainsLen = _participantChains[_flowId].length;
        if (_execParams.length != chainsLen) revert CommitCountMismatch(chainsLen, _execParams.length);
        uint256 totalMintValue;
        for (uint256 i; i < chainsLen; ++i) {
            totalMintValue += _execParams[i].mintValue;
        }
        if (msg.value != totalMintValue) revert MintValueSumMismatch(totalMintValue, msg.value);
    }

    function _dispatchExecuteOne(bytes32 _flowId, uint256 _chainId, ExecuteParams calldata _params) internal {
        SendSpec[] memory inboundSpecs = _collectInbound(_flowId, _chainId);
        bytes memory calldataPayload = abi.encodeCall(IL2FlowEscrow.executeFromL1, (_flowId, inboundSpecs));
        bytes32 canonicalTxHash = _dispatch(_chainId, _participantEscrow[_flowId][_chainId], _params, calldataPayload);
        emit FlowExecuteDispatched(_flowId, _chainId, canonicalTxHash);
    }

    /// @dev Refund dispatch is a no-op for receive-only chains (no lock to refund). The
    /// caller must still pass an `ExecuteParams` entry with `mintValue == 0` so the array
    /// stays aligned with the participating set.
    function _dispatchRefundOne(
        bytes32 _flowId,
        uint256 _chainId,
        ExecuteParams calldata _params,
        bytes memory _calldataPayload
    ) internal {
        if (!_hasCommit[_flowId][_chainId]) {
            if (_params.mintValue != 0) revert MintValueSumMismatch(0, _params.mintValue);
            return;
        }
        bytes32 canonicalTxHash = _dispatch(_chainId, _participantEscrow[_flowId][_chainId], _params, _calldataPayload);
        emit FlowRefundDispatched(_flowId, _chainId, canonicalTxHash);
    }

    /// @inheritdoc IL1FlowLinker
    function flowState(bytes32 _flowId) external view returns (FlowState) {
        return _flows[_flowId].state;
    }

    function flowDeadline(bytes32 _flowId) external view returns (uint64) {
        return _flows[_flowId].deadline;
    }

    function participants(bytes32 _flowId) external view returns (uint256[] memory chainIds, address[] memory escrows) {
        uint256[] storage chains = _participantChains[_flowId];
        uint256 n = chains.length;
        chainIds = new uint256[](n);
        escrows = new address[](n);
        for (uint256 i; i < n; ++i) {
            chainIds[i] = chains[i];
            escrows[i] = _participantEscrow[_flowId][chains[i]];
        }
    }

    function commit(bytes32 _flowId, uint256 _chainId) external view returns (bool hasCommitted, SendSpec memory spec) {
        return (_hasCommit[_flowId][_chainId], _commits[_flowId][_chainId]);
    }

    /// @dev Walk all committed senders, collecting every `SendSpec` whose `destChainId`
    /// equals `_destChainId`. With n participants this is O(n) per dispatched chain
    /// (O(n²) overall) — fine for the small n flows we care about.
    function _collectInbound(bytes32 _flowId, uint256 _destChainId) internal view returns (SendSpec[] memory) {
        uint256[] storage chains = _participantChains[_flowId];
        uint256 n = chains.length;

        uint256 inboundCount;
        for (uint256 i; i < n; ++i) {
            uint256 src = chains[i];
            if (!_hasCommit[_flowId][src]) continue;
            if (_commits[_flowId][src].destChainId == _destChainId) ++inboundCount;
        }

        SendSpec[] memory result = new SendSpec[](inboundCount);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            uint256 src = chains[i];
            if (!_hasCommit[_flowId][src]) continue;
            if (_commits[_flowId][src].destChainId == _destChainId) {
                result[j] = _commits[_flowId][src];
                ++j;
            }
        }
        return result;
    }

    function _dispatch(
        uint256 _chainId,
        address _l2Escrow,
        ExecuteParams calldata _params,
        bytes memory _calldata
    ) internal returns (bytes32 canonicalTxHash) {
        L2TransactionRequestDirect memory req = L2TransactionRequestDirect({
            chainId: _chainId,
            mintValue: _params.mintValue,
            l2Contract: _l2Escrow,
            l2Value: 0,
            l2Calldata: _calldata,
            l2GasLimit: _params.l2GasLimit,
            l2GasPerPubdataByteLimit: _params.l2GasPerPubdataByteLimit,
            factoryDeps: new bytes[](0),
            refundRecipient: _params.refundRecipient
        });
        canonicalTxHash = BRIDGEHUB.requestL2TransactionDirect{value: _params.mintValue}(req);
    }
}
