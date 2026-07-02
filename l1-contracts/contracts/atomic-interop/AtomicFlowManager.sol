// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAtomicFlowManager} from "./IAtomicFlowManager.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IAtomicRecoverable} from "./IAtomicRecoverable.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {LegState, AtomicTimeoutProof, AtomicFinalityProof} from "./IAtomicInterop.sol";
import {InteropBundle, InteropCall} from "../common/Messaging.sol";
import {InteropDataEncoding} from "../interop/InteropDataEncoding.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    ManagerNotInteropCenter,
    ManagerNotInteropHandler,
    ManagerLegAlreadyCommitted,
    ManagerLegNotRevertable,
    ManagerFlowIdMismatch,
    ManagerBundleHashesNotSorted,
    ManagerLegSourceChainIdsLengthMismatch,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerNoRecoverableCalls,
    ManagerCallNotRecovered,
    ProofSourceChainMismatch
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowManager}. Coordinator for the L1-free atomic interop flow; it never holds funds.
///
/// Send: {InteropCenter.sendBundle} burns via the normal `initiateIndirectCall` path, then — when the
/// bundle carries the `atomicBundle` attribute — calls {append} instead of publishing to L1. `append`
/// records the leg's commit value in this chain's {L2InteropCommitmentTree}.
/// Receive: {InteropHandler.executeAtomicBundle} calls {requireFlowFinalized} in place of the L1-message
/// inclusion proof, then executes the bundle (and owns the replay guard).
/// Timeout: {authorizeRefund} + {claimRefund} return the burned source funds to the depositor by asking
/// each call target to reverse itself via {IAtomicRecoverable.recoverAtomicCall}.
///
/// No double-spend: executing a bundle requires every leg present in a batch whose `l1Timestamp <=
/// deadline`, while a refund requires some leg absent from the last such batch (pinned by the next batch
/// with `l1Timestamp > deadline`). Since the per-chain trees are append-only and `l1Timestamp` is monotone, both cannot
/// hold — but only when both proofs are checked against the leg's own source chain on the same settlement
/// layer. Both bindings are committed in `flowId`. Without the source-chain binding a leg's commit value
/// is trivially absent from any other chain's tree, re-opening a cross-chain force-refund double-mint.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev (flowId, bundleHash) => source-leg state on this chain. The commitment tree, interop center
    /// and interop handler are genesis-deployed built-ins at fixed addresses, so they are constants
    /// rather than stored/initialized.
    mapping(bytes32 flowId => mapping(bytes32 bundleHash => LegState)) internal _state;

    modifier onlyInteropCenter() {
        if (msg.sender != interopCenter()) revert ManagerNotInteropCenter(msg.sender);
        _;
    }

    modifier onlyInteropHandler() {
        if (msg.sender != interopHandler()) revert ManagerNotInteropHandler(msg.sender);
        _;
    }

    /// @inheritdoc IAtomicFlowManager
    function append(
        bytes32 _flowId,
        bytes32 _bundleHash,
        uint64 _deadline,
        uint256 _lowNullifierIndex
    ) external onlyInteropCenter {
        if (_state[_flowId][_bundleHash] != LegState.Unset) revert ManagerLegAlreadyCommitted(_flowId, _bundleHash);
        // Effects before interaction: mark committed before touching the tree.
        _state[_flowId][_bundleHash] = LegState.Committed;

        uint256 value = AtomicInteropProof.commitValue(_flowId, _bundleHash);
        // slither-disable-next-line unused-return
        (uint256 index, ) = IL2InteropCommitmentTree(commitmentTree()).insert(value, _lowNullifierIndex);

        emit FlowCommitted(_flowId, _bundleHash, _deadline, index);
    }

    /// @inheritdoc IAtomicFlowManager
    function requireFlowFinalized(
        bytes32 _executingBundleHash,
        AtomicFinalityProof calldata _finality
    ) external view onlyInteropHandler {
        // solhint-disable-next-line func-named-parameters
        _checkFlowId(
            _finality.flowId,
            _finality.legBundleHashes,
            _finality.legSourceChainIds,
            _finality.deadline,
            _finality.settlementLayerChainId
        );

        uint256 n = _finality.legBundleHashes.length;
        if (_finality.proofs.length != n) revert ManagerProofCountMismatch(n, _finality.proofs.length);

        // Every leg must be present in its source chain's tree as of a root settled no later than the
        // deadline. Each proof's `sourceChainId` must equal the leg's declared `legSourceChainIds[i]`:
        // defense-in-depth here (membership already self-binds via the chain-specific `commitValue`) but
        // load-bearing for the symmetric refund path. The proof's settlement layer must match the flow's
        // `settlementLayerChainId`, checked inside {AtomicInteropProof.verifyInclusion}.
        bool executingIsLeg = false;
        for (uint256 i = 0; i < n; ++i) {
            if (_finality.legBundleHashes[i] == _executingBundleHash) executingIsLeg = true;
            if (_finality.proofs[i].sourceChainId != _finality.legSourceChainIds[i]) {
                revert ProofSourceChainMismatch(_finality.legSourceChainIds[i], _finality.proofs[i].sourceChainId);
            }
            uint256 value = AtomicInteropProof.commitValue(_finality.flowId, _finality.legBundleHashes[i]);
            AtomicInteropProof.verifyInclusion(
                _finality.proofs[i],
                value,
                _finality.deadline,
                _finality.settlementLayerChainId
            );
        }
        if (!executingIsLeg) revert ManagerExecutingBundleNotInFlow(_finality.flowId, _executingBundleHash);
    }

    /// @inheritdoc IAtomicFlowManager
    function authorizeRefund(
        bytes32 _flowId,
        bytes32[] calldata _legBundleHashes,
        uint256[] calldata _legSourceChainIds,
        uint64 _deadline,
        uint256 _settlementLayerChainId,
        uint256 _missingLegIndex,
        AtomicTimeoutProof calldata _timeout
    ) external {
        // solhint-disable-next-line func-named-parameters
        _checkFlowId(_flowId, _legBundleHashes, _legSourceChainIds, _deadline, _settlementLayerChainId);

        // 1. Bind the absence proof to the missing leg's declared source chain. Without this, the leg's
        //    commit value — which exists only in its own source chain's tree — is trivially absent from
        //    any other chain's tree, so an on-time, finalized leg could be force-refunded against an
        //    unrelated chain (double-mint).
        if (_timeout.absence.sourceChainId != _legSourceChainIds[_missingLegIndex]) {
            revert ProofSourceChainMismatch(_legSourceChainIds[_missingLegIndex], _timeout.absence.sourceChainId);
        }

        // 2. Adjacency timeout: the leg's commit value is absent from the last batch with settlement
        //    timestamp `t <= deadline` (the absence proof), pinned by the next batch with `t > deadline`
        //    (the successor witness). This closes the stale/genesis-root force-refund: an old/empty root
        //    can't be used because its successor would still be `<= deadline`.
        uint256 value = AtomicInteropProof.commitValue(_flowId, _legBundleHashes[_missingLegIndex]);
        // solhint-disable-next-line func-named-parameters
        AtomicInteropProof.verifyTimeoutAdjacency(
            _timeout.absence,
            _timeout.successor,
            value,
            _deadline,
            _settlementLayerChainId
        );

        // 3. Mark this chain's committed source legs Revertable (legs committed on other chains are not
        //    in this manager's state, so they are skipped).
        uint256 n = _legBundleHashes.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 h = _legBundleHashes[i];
            if (_state[_flowId][h] != LegState.Committed) continue;
            _state[_flowId][h] = LegState.Revertable;
            emit FlowRefundAuthorized(_flowId, h);
        }
    }

    /// @inheritdoc IAtomicFlowManager
    function claimRefund(bytes32 _flowId, bytes calldata _bundle) external {
        InteropBundle memory bundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundle.sourceChainId, _bundle);

        LegState s = _state[_flowId][bundleHash];
        if (s != LegState.Revertable) revert ManagerLegNotRevertable(_flowId, bundleHash, s);
        // No `nonReentrant` guard: safety rests on CEI plus the per-leg state machine. The leg is flipped
        // to `Reverted` before `_recoverBundle`'s external calls, so a reentrant claim for this leg hits
        // the `Revertable` check above and reverts; a claim for a different leg is independent and equally
        // guarded (no shared mutable state). The manager never holds funds.
        _state[_flowId][bundleHash] = LegState.Reverted;

        _recoverBundle(_flowId, bundleHash, bundle);

        emit FlowRefunded(_flowId, bundleHash);
    }

    /// @inheritdoc IAtomicFlowManager
    function legState(bytes32 _flowId, bytes32 _bundleHash) external view returns (LegState) {
        return _state[_flowId][_bundleHash];
    }

    /// @inheritdoc IAtomicFlowManager
    function commitmentTree() public view virtual returns (address) {
        return L2_INTEROP_COMMITMENT_TREE_ADDR;
    }

    /// @inheritdoc IAtomicFlowManager
    function interopCenter() public view virtual returns (address) {
        return L2_INTEROP_CENTER_ADDR;
    }

    /// @inheritdoc IAtomicFlowManager
    function interopHandler() public view virtual returns (address) {
        return L2_INTEROP_HANDLER_ADDR;
    }

    /// @dev Reverses every call in `_bundle`, re-crediting the original depositor. Each call's target
    /// (`InteropCall.to`) owns its reversal via {IAtomicRecoverable.recoverAtomicCall}; the manager is
    /// agnostic to the encoding and just forwards `(destinationChainId, data)` to each target.
    /// Every call must report a recovery, since one non-recovered call would strand funds while the leg
    /// becomes terminally `Reverted`. The send-time gate ({InteropCenter._validateAtomicBundleRefundable})
    /// only commits recoverable asset-router calls, so a genuine leg recovers in full; the all-recovered
    /// check guards against any non-recoverable call slipping through.
    function _recoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        uint256 callsLen = _bundle.calls.length;
        if (callsLen == 0) revert ManagerNoRecoverableCalls(_flowId, _bundleHash);
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            if (!IAtomicRecoverable(c.to).recoverAtomicCall(destChainId, c.data)) {
                revert ManagerCallNotRecovered(_flowId, _bundleHash, i);
            }
        }
    }

    /// @dev Recomputes `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline,
    /// settlementLayerChainId))` and asserts it matches. `_legBundleHashes` must be strictly ascending
    /// (canonical order + dedup). `_legSourceChainIds` is positional, aligned 1:1 with `_legBundleHashes`;
    /// it may repeat and need not be ascending, so only its length is checked. Treating it as an
    /// ascending set instead would let a sibling chain in the set still enable a wrong-chain refund.
    function _checkFlowId(
        bytes32 _flowId,
        bytes32[] calldata _legBundleHashes,
        uint256[] calldata _legSourceChainIds,
        uint64 _deadline,
        uint256 _settlementLayerChainId
    ) internal pure {
        uint256 n = _legBundleHashes.length;
        for (uint256 i = 1; i < n; ++i) {
            if (_legBundleHashes[i] <= _legBundleHashes[i - 1]) revert ManagerBundleHashesNotSorted();
        }
        if (_legSourceChainIds.length != n) {
            revert ManagerLegSourceChainIdsLengthMismatch(n, _legSourceChainIds.length);
        }
        bytes32 computed = keccak256(
            abi.encode(_legBundleHashes, _legSourceChainIds, _deadline, _settlementLayerChainId)
        );
        if (computed != _flowId) revert ManagerFlowIdMismatch(_flowId, computed);
    }
}
