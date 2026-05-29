// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL1FlowLinker, CommitProof, ExecuteParams, FlowState} from "./IL1FlowLinker.sol";
import {IL2FlowEscrow} from "./IL2FlowEscrow.sol";
import {COMMIT_LOG_TAG} from "./IDummyFlow.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestDirect} from "../core/bridgehub/IBridgehubBase.sol";
import {IMessageVerification} from "../common/interfaces/IMessageVerification.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {
    ChainsNotSorted,
    CommitChainNotInParticipants,
    CommitLogFlowIdMismatch,
    CommitLogNotIncluded,
    CommitLogSenderMismatch,
    CommitLogTagMismatch,
    DeadlineInPast,
    DestChainNotInParticipants,
    DuplicateCommit,
    DuplicateParticipantChain,
    EmptyParticipantSet,
    ExecParamsLengthMismatch,
    FlowAlreadyRegistered,
    FlowExpired,
    FlowIdMismatch,
    FlowNotExpired,
    FlowNotFinalized,
    FlowNotInitiated,
    LinkerAlreadyInitialized,
    LinkerEscrowNotRegistered,
    LinkerInitEmptyChainIds,
    LinkerInitEscrowLenMismatch,
    LinkerInitZeroEscrow,
    LinkerNotInitialized,
    MintValueSumMismatch
} from "./DummyFlowErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IL1FlowLinker`. Owns flow lifecycle on L1, verifies per-chain commit logs
/// via `IMessageVerification`, and drives finality by dispatching one L1→L2 priority tx
/// per participating chain via `Bridgehub.requestL2TransactionDirect`. ETH-base chains
/// only in V1.
contract L1FlowLinker is IL1FlowLinker, ReentrancyGuard {
    IL1Bridgehub public immutable BRIDGEHUB;
    IMessageVerification public immutable MESSAGE_VERIFICATION;

    /// @dev Per-chain L2 escrow addresses. Populated by `initialize`. Used as both the
    /// expected commit-log `sender` (in `_ingestOneCommit`) and the `l2Contract` target of
    /// the L1->L2 priority tx (in `_dispatch`).
    mapping(uint256 chainId => address) public escrowOf;

    /// @dev True once `initialize` has been called. We can't gate on `escrowOf` alone
    /// because a chain could legitimately register `address(0)` if the deployer wanted to
    /// — though we forbid that in `initialize`, the explicit flag still keeps the check
    /// cheap and unambiguous.
    bool internal _initialized;

    struct Flow {
        FlowState state;
        uint64 deadline;
        address registrar;
    }

    mapping(bytes32 flowId => Flow) internal _flows;
    /// @dev Sorted ascending; uniqueness enforced at `registerFlow`.
    mapping(bytes32 flowId => uint256[]) internal _participantChains;

    /// @dev For each chain that committed at least one spec for this flow: the spec hashes
    /// it committed. Populated during `recordFinalitySignal`. Used by `executeFlow` to
    /// route hashes to authorize-dispatches and by `revertFlow` to know which chains have
    /// locks to refund.
    mapping(bytes32 flowId => mapping(uint256 chainId => bytes32[])) internal _committedHashes;
    /// @dev For each committed spec hash: the destination chain id (extracted from the
    /// commit log). Used by `executeFlow` to route mint-dispatches.
    mapping(bytes32 flowId => mapping(bytes32 specHash => uint256)) internal _destChainOf;

    constructor(IL1Bridgehub _bridgehub, IMessageVerification _messageVerification) reentrancyGuardInitializer {
        BRIDGEHUB = _bridgehub;
        MESSAGE_VERIFICATION = _messageVerification;
    }

    /// @inheritdoc IL1FlowLinker
    function initialize(uint256[] calldata _chainIds, address[] calldata _escrows) external {
        if (_initialized) revert LinkerAlreadyInitialized();
        uint256 n = _chainIds.length;
        if (n == 0) revert LinkerInitEmptyChainIds();
        if (n != _escrows.length) revert LinkerInitEscrowLenMismatch(n, _escrows.length);
        for (uint256 i; i < n; ++i) {
            if (_escrows[i] == address(0)) revert LinkerInitZeroEscrow(_chainIds[i]);
            escrowOf[_chainIds[i]] = _escrows[i];
        }
        _initialized = true;
    }

    /// @inheritdoc IL1FlowLinker
    function registerFlow(bytes32 _flowId, uint256[] calldata _chainIds, uint64 _deadline) external {
        if (!_initialized) revert LinkerNotInitialized();
        if (_flows[_flowId].state != FlowState.None) revert FlowAlreadyRegistered(_flowId);
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);

        uint256 n = _chainIds.length;
        if (n == 0) revert EmptyParticipantSet();

        // Require sorted-ascending + dedup. This is the canonical ordering callers should
        // use when computing flowId-derived data off-chain and lets membership checks be
        // linear-scan instead of mapping reads.
        uint256 prev;
        for (uint256 i; i < n; ++i) {
            uint256 c = _chainIds[i];
            if (i > 0 && c <= prev) {
                if (c == prev) revert DuplicateParticipantChain(c);
                revert ChainsNotSorted();
            }
            // Fail early: every participating chain must already have an escrow registered.
            if (escrowOf[c] == address(0)) revert LinkerEscrowNotRegistered(c);
            _participantChains[_flowId].push(c);
            prev = c;
        }

        _flows[_flowId] = Flow({state: FlowState.Initiated, deadline: _deadline, registrar: msg.sender});
        emit FlowRegistered(_flowId, msg.sender, _deadline);
    }

    /// @inheritdoc IL1FlowLinker
    function recordFinalitySignal(bytes32 _flowId, CommitProof[] calldata _proofs) external nonReentrant {
        Flow storage flow = _flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp > flow.deadline) revert FlowExpired(_flowId);

        bytes32[] memory collected = _ingestAllCommits(_flowId, _proofs);

        // Completeness check: the registered flowId IS the hash commitment to the full
        // expected (specs, chainIds, deadline) tuple. Anything missing/extra in the spec
        // set fails this equality. Binding the chain set and the deadline into the hash
        // (in addition to the spec hashes) prevents a frontrunning attacker from racing
        // `registerFlow` with the same spec set but a different chain set or earlier
        // deadline.
        bytes32[] memory sorted = _sortHashes(collected);
        bytes32 computedFlowId = keccak256(abi.encode(sorted, _participantChains[_flowId], flow.deadline));
        if (computedFlowId != _flowId) revert FlowIdMismatch(_flowId, computedFlowId);

        // Closure: every destination referenced by any commit must be in the participating
        // set. Combined with the flowId hash check, this guarantees the graph closes.
        for (uint256 i; i < sorted.length; ++i) {
            uint256 dest = _destChainOf[_flowId][sorted[i]];
            if (!_isParticipant(_flowId, dest)) revert DestChainNotInParticipants(dest);
        }

        flow.state = FlowState.Finalized;
        emit FlowFinalized(_flowId);
    }

    /// @inheritdoc IL1FlowLinker
    function executeFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable nonReentrant {
        if (_flows[_flowId].state != FlowState.Finalized) revert FlowNotFinalized(_flowId);
        _checkExecParams(_flowId, _execParams);

        uint256[] storage chains = _participantChains[_flowId];
        uint256 chainsLen = chains.length;
        for (uint256 i; i < chainsLen; ++i) {
            _dispatchAuthorize(_flowId, chains[i], _execParams[i]);
        }
    }

    /// @inheritdoc IL1FlowLinker
    function revertFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable nonReentrant {
        Flow storage flow = _flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp <= flow.deadline) revert FlowNotExpired(_flowId, flow.deadline);

        _checkExecParams(_flowId, _execParams);

        flow.state = FlowState.Reverted;
        emit FlowReverted(_flowId);

        uint256[] storage chains = _participantChains[_flowId];
        uint256 chainsLen = chains.length;
        for (uint256 i; i < chainsLen; ++i) {
            _dispatchRefund(_flowId, chains[i], _execParams[i]);
        }
    }

    /// @inheritdoc IL1FlowLinker
    function flowState(bytes32 _flowId) external view returns (FlowState) {
        return _flows[_flowId].state;
    }

    function participantChains(bytes32 _flowId) external view returns (uint256[] memory) {
        return _participantChains[_flowId];
    }

    function committedHashesFor(bytes32 _flowId, uint256 _chainId) external view returns (bytes32[] memory) {
        return _committedHashes[_flowId][_chainId];
    }

    /*//////////////////////////////////////////////////////////////
                                Internals
    //////////////////////////////////////////////////////////////*/

    /// @dev Verify + ingest each commit proof. Returns the deduped array of all spec
    /// hashes seen. Reverts on tag/sender/flowId mismatch, duplicate hash, or commit-chain
    /// not in the participating set.
    function _ingestAllCommits(bytes32 _flowId, CommitProof[] calldata _proofs) internal returns (bytes32[] memory) {
        uint256 n = _proofs.length;
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = _ingestOneCommit(_flowId, _proofs[i]);
        }
        return hashes;
    }

    function _ingestOneCommit(bytes32 _flowId, CommitProof calldata _proof) internal returns (bytes32) {
        // Escrow expected on this specific chain. `registerFlow` already guaranteed every
        // participant chain has a non-zero entry, but a non-participant chain's proof
        // would yield `address(0)` here — still caught below by the participant check.
        address expected = escrowOf[_proof.chainId];
        if (_proof.message.sender != expected) {
            revert CommitLogSenderMismatch(_proof.chainId, _proof.message.sender);
        }
        if (!_isParticipant(_flowId, _proof.chainId)) revert CommitChainNotInParticipants(_proof.chainId);

        bool included = MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _proof.chainId,
            _blockOrBatchNumber: _proof.blockOrBatchNumber,
            _index: _proof.messageIndex,
            _message: _proof.message,
            _proof: _proof.merkleProof
        });
        if (!included) revert CommitLogNotIncluded(_proof.chainId);

        (bytes4 tag, bytes32 logFlowId, uint256 destChainId, bytes32 specHash) = abi.decode(
            _proof.message.data,
            (bytes4, bytes32, uint256, bytes32)
        );
        if (tag != COMMIT_LOG_TAG) revert CommitLogTagMismatch(tag);
        if (logFlowId != _flowId) revert CommitLogFlowIdMismatch(logFlowId);

        if (_destChainOf[_flowId][specHash] != 0) revert DuplicateCommit(specHash);
        _destChainOf[_flowId][specHash] = destChainId;
        _committedHashes[_flowId][_proof.chainId].push(specHash);

        return specHash;
    }

    function _isParticipant(bytes32 _flowId, uint256 _chainId) internal view returns (bool) {
        uint256[] storage chains = _participantChains[_flowId];
        uint256 n = chains.length;
        for (uint256 i; i < n; ++i) {
            if (chains[i] == _chainId) return true;
        }
        return false;
    }

    /// @dev In-place insertion sort. Spec sets are small (≤ chainsLen for typical flows),
    /// so O(n²) is fine.
    function _sortHashes(bytes32[] memory _arr) internal pure returns (bytes32[] memory) {
        uint256 n = _arr.length;
        for (uint256 i = 1; i < n; ++i) {
            bytes32 key = _arr[i];
            uint256 j = i;
            while (j > 0 && _arr[j - 1] > key) {
                _arr[j] = _arr[j - 1];
                --j;
            }
            _arr[j] = key;
        }
        return _arr;
    }

    /// @dev Validates `_execParams.length` matches the participating set size and that
    /// `msg.value` equals the sum of per-chain `mintValue`s.
    function _checkExecParams(bytes32 _flowId, ExecuteParams[] calldata _execParams) internal view {
        uint256 chainsLen = _participantChains[_flowId].length;
        if (_execParams.length != chainsLen) revert ExecParamsLengthMismatch(chainsLen, _execParams.length);
        uint256 totalMintValue;
        for (uint256 i; i < chainsLen; ++i) {
            totalMintValue += _execParams[i].mintValue;
        }
        if (msg.value != totalMintValue) revert MintValueSumMismatch(totalMintValue, msg.value);
    }

    /// @dev Build the spec-hash list for chain `_chainId`: union of (a) hashes it
    /// committed (sender-side) and (b) hashes whose destChain == it (receiver-side).
    function _hashesForChain(bytes32 _flowId, uint256 _chainId) internal view returns (bytes32[] memory) {
        uint256 count = _countInboundFor(_flowId, _chainId) + _committedHashes[_flowId][_chainId].length;
        bytes32[] memory out = new bytes32[](count);
        uint256 k = _fillOwnHashes(_flowId, _chainId, out, 0);
        _fillInboundHashes(_flowId, _chainId, out, k);
        return out;
    }

    function _countInboundFor(bytes32 _flowId, uint256 _chainId) internal view returns (uint256) {
        uint256[] storage chains = _participantChains[_flowId];
        uint256 n = chains.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            uint256 src = chains[i];
            if (src == _chainId) continue;
            bytes32[] storage srcHashes = _committedHashes[_flowId][src];
            uint256 m = srcHashes.length;
            for (uint256 j; j < m; ++j) {
                if (_destChainOf[_flowId][srcHashes[j]] == _chainId) ++count;
            }
        }
        return count;
    }

    function _fillOwnHashes(
        bytes32 _flowId,
        uint256 _chainId,
        bytes32[] memory _out,
        uint256 _k
    ) internal view returns (uint256) {
        bytes32[] storage own = _committedHashes[_flowId][_chainId];
        uint256 n = own.length;
        for (uint256 i; i < n; ++i) {
            _out[_k++] = own[i];
        }
        return _k;
    }

    function _fillInboundHashes(bytes32 _flowId, uint256 _chainId, bytes32[] memory _out, uint256 _k) internal view {
        uint256[] storage chains = _participantChains[_flowId];
        uint256 n = chains.length;
        for (uint256 i; i < n; ++i) {
            uint256 src = chains[i];
            if (src == _chainId) continue;
            bytes32[] storage srcHashes = _committedHashes[_flowId][src];
            uint256 m = srcHashes.length;
            for (uint256 j; j < m; ++j) {
                if (_destChainOf[_flowId][srcHashes[j]] == _chainId) {
                    _out[_k++] = srcHashes[j];
                }
            }
        }
    }

    function _dispatchAuthorize(bytes32 _flowId, uint256 _chainId, ExecuteParams calldata _params) internal {
        bytes32[] memory hashes = _hashesForChain(_flowId, _chainId);
        bytes memory payload = abi.encodeCall(IL2FlowEscrow.authorizeFromL1, (_flowId, hashes));
        bytes32 canonicalTxHash = _dispatch(_chainId, _params, payload);
        emit FlowExecuteDispatched(_flowId, _chainId, canonicalTxHash);
    }

    function _dispatchRefund(bytes32 _flowId, uint256 _chainId, ExecuteParams calldata _params) internal {
        // Only chains that committed something have anything to refund. Chains that didn't
        // commit must still pass an ExecuteParams entry (for index alignment) but with
        // mintValue == 0 — we skip dispatching to them.
        bytes32[] storage committed = _committedHashes[_flowId][_chainId];
        if (committed.length == 0) {
            if (_params.mintValue != 0) revert MintValueSumMismatch(0, _params.mintValue);
            return;
        }
        bytes32[] memory hashes = new bytes32[](committed.length);
        for (uint256 i; i < committed.length; ++i) {
            hashes[i] = committed[i];
        }
        bytes memory payload = abi.encodeCall(IL2FlowEscrow.authorizeRefundFromL1, (_flowId, hashes));
        bytes32 canonicalTxHash = _dispatch(_chainId, _params, payload);
        emit FlowRefundDispatched(_flowId, _chainId, canonicalTxHash);
    }

    function _dispatch(
        uint256 _chainId,
        ExecuteParams calldata _params,
        bytes memory _calldata
    ) internal returns (bytes32 canonicalTxHash) {
        // Per-chain escrow target. `registerFlow` has already enforced non-zero entry for
        // every participant; this read just resolves which address to dispatch to.
        L2TransactionRequestDirect memory req = L2TransactionRequestDirect({
            chainId: _chainId,
            mintValue: _params.mintValue,
            l2Contract: escrowOf[_chainId],
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
