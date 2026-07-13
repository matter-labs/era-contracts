// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAtomicFlowManager} from "./IAtomicFlowManager.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IAtomicRecoverable} from "./IAtomicRecoverable.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {LegState, AtomicFlow, ImtProof, AtomicFinalityProof} from "./IAtomicInterop.sol";
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
    ProofSourceChainMismatch
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowManager}. Fund-touchless coordinator for the L1-free atomic interop flow.
///
/// Send: {InteropCenter.sendBundle} burns through the normal `initiateIndirectCall` path, then — when
/// the bundle carries the `atomicBundle` attribute — calls {append} instead of publishing the bundle
/// to L1; `append` records the leg's commit value in this chain's {L2InteropCommitmentTree}.
/// Receive: {InteropHandler.executeAtomicBundle} calls {requireFlowFinalized} (the atomicity gate) in
/// place of the L1-message inclusion proof, then executes the bundle (and owns the replay guard).
/// Timeout: {authorizeRefund} + {claimRefund} recover the burned source funds to the depositor by
/// asking each of the bundle's call targets to reverse itself via {IAtomicRecoverable.recoverAtomicCall}.
///
/// No double-spend: executing a bundle requires every leg present in the batch-END IMT root of a batch
/// whose `l1Timestamp < deadline`, while a refund is anchored on an aggregated root created after the
/// deadline and requires some leg absent from the batch-BEGIN IMT root of a late batch
/// (`l1Timestamp >= deadline`) or from the batch-END IMT root of the chain's last batch inside that
/// root. Since the per-chain trees are append-only, `begin(N) == end(N-1)`, and `l1Timestamp` is
/// monotone, finalization and refund cannot both hold — but only when both proofs are checked against
/// the leg's own source chain on the same settlement layer. Both bindings are committed in `flowId`.
/// Without the source-chain binding a leg's commit value is trivially absent from any other chain's
/// tree, re-opening a cross-chain force-refund double-mint.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev (flowId, bundleHash) => source-leg state on this chain. All collaborators
    /// (commitment tree, interop center, interop handler) are genesis-deployed built-ins
    /// at canonical fixed addresses, so they are referenced as constants rather than stored/initialized.
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
        AtomicFlow calldata flow = _finality.flow;
        _checkFlowId(flow);

        uint256 n = flow.legBundleHashes.length;
        if (_finality.proofs.length != n) revert ManagerProofCountMismatch(n, _finality.proofs.length);

        // Every leg must be present in its source chain's tree as of a root settled no later than the
        // deadline. Each proof's `sourceChainId` must equal the leg's declared `legSourceChainIds[i]`:
        // defense-in-depth here (membership already self-binds via the chain-specific `commitValue`) but
        // load-bearing for the symmetric refund path. The proof's settlement layer must match the flow's
        // `settlementLayerChainId`, checked inside {AtomicInteropProof.verifyInclusion}.
        bool executingIsLeg = false;
        for (uint256 i = 0; i < n; ++i) {
            if (flow.legBundleHashes[i] == _executingBundleHash) executingIsLeg = true;
            if (_finality.proofs[i].sourceChainId != flow.legSourceChainIds[i]) {
                revert ProofSourceChainMismatch(flow.legSourceChainIds[i], _finality.proofs[i].sourceChainId);
            }
            uint256 value = AtomicInteropProof.commitValue(flow.flowId, flow.legBundleHashes[i]);
            AtomicInteropProof.verifyInclusion(_finality.proofs[i], value, flow.deadline, flow.settlementLayerChainId);
        }
        if (!executingIsLeg) revert ManagerExecutingBundleNotInFlow(flow.flowId, _executingBundleHash);
    }

    /// @inheritdoc IAtomicFlowManager
    function authorizeRefund(AtomicFlow calldata _flow, uint256 _missingLegIndex, ImtProof calldata _absence) external {
        _checkFlowId(_flow);

        // 1. Bind the absence proof to the missing leg's declared source chain. Without this, the leg's
        //    commit value — which exists only in its own source chain's tree — is trivially absent from
        //    any other chain's tree, so an on-time, finalized leg could be force-refunded against an
        //    unrelated chain (double-mint).
        uint256 missingLegChainId = _flow.legSourceChainIds[_missingLegIndex];
        if (_absence.sourceChainId != missingLegChainId) {
            revert ProofSourceChainMismatch(missingLegChainId, _absence.sourceChainId);
        }

        // 2. Timeout: anchored on an aggregated root created after the deadline, the leg's commit
        //    value is absent from the batch-BEGIN IMT root of a late batch (`t >= deadline`) or from
        //    the batch-END IMT root of the chain's last batch inside that root (`t < deadline`).
        //    Append-only + `begin(N) == end(N-1)` + monotone `t` make either branch equivalent to
        //    absence from every in-time batch, so the flow can never finalize. Requiring the anchor
        //    root to be from after the deadline closes the stale/genesis-root force-refund: an
        //    in-time snapshot proves nothing about the deadline moment.
        uint256 value = AtomicInteropProof.commitValue(_flow.flowId, _flow.legBundleHashes[_missingLegIndex]);
        AtomicInteropProof.verifyTimeoutAbsence(_absence, value, _flow.deadline, _flow.settlementLayerChainId);

        // 3. Mark this chain's committed source legs Revertable (legs committed on other chains are not
        //    in this manager's state, so they are skipped).
        uint256 n = _flow.legBundleHashes.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 h = _flow.legBundleHashes[i];
            if (_state[_flow.flowId][h] != LegState.Committed) continue;
            _state[_flow.flowId][h] = LegState.Revertable;
            emit FlowRefundAuthorized(_flow.flowId, h);
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

    /// @dev Reverses every recoverable call embedded in `_bundle`, re-crediting the original depositor.
    /// Each call's target (`InteropCall.to`) owns its own reversal via {IAtomicRecoverable.recoverAtomicCall}:
    /// the manager is agnostic to the call/encoding format and simply forwards `(destinationChainId, data)`
    /// to every target, counting the ones that report a recovery. Targets must return `false` (not revert)
    /// for calls they do not recognise.
    ///
    /// Recovery is best-effort by design. An atomic bundle may mix fund-moving calls (e.g. asset-router
    /// deposits, which re-mint to the depositor) with calls that move no funds and have nothing to reverse
    /// (e.g. flipping a flag on some contract). The latter legitimately return `false` and are skipped —
    /// they burned nothing at the source, so nothing is stranded. We only require that *some* call recovered
    /// (`recovered != 0`): a bundle where nothing is recoverable has no source funds to return, so a refund
    /// would be a no-op and we reject it.
    ///
    /// Consequence: the protocol does not guarantee full refundability of an arbitrary bundle. A flow author
    /// must make any fund-moving leg a recoverable (asset-router) call to have it returned on timeout; a
    /// non-recoverable fund-moving call would strand its funds. Send-time ({InteropCenter}) only blocks
    /// native-`value` legs, which no one can reverse.
    function _recoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        uint256 callsLen = _bundle.calls.length;
        uint256 recovered = 0;
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            if (IAtomicRecoverable(c.to).recoverAtomicCall(destChainId, c.data)) {
                ++recovered;
            }
        }
        if (recovered == 0) revert ManagerNoRecoverableCalls(_flowId, _bundleHash);
    }

    /// @dev Recomputes `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline,
    /// settlementLayerChainId))` and asserts it matches `_flow.flowId`. `legBundleHashes` must be strictly
    /// ascending (canonical order + dedup). `legSourceChainIds` is positional, aligned 1:1 with
    /// `legBundleHashes`; it may repeat and need not be ascending, so only its length is checked. Treating
    /// it as an ascending set instead would let a sibling chain in the set still enable a wrong-chain refund.
    function _checkFlowId(AtomicFlow calldata _flow) internal pure {
        uint256 n = _flow.legBundleHashes.length;
        for (uint256 i = 1; i < n; ++i) {
            if (_flow.legBundleHashes[i] <= _flow.legBundleHashes[i - 1]) revert ManagerBundleHashesNotSorted();
        }
        if (_flow.legSourceChainIds.length != n) {
            revert ManagerLegSourceChainIdsLengthMismatch(n, _flow.legSourceChainIds.length);
        }
        bytes32 computed = keccak256(
            abi.encode(_flow.legBundleHashes, _flow.legSourceChainIds, _flow.deadline, _flow.settlementLayerChainId)
        );
        if (computed != _flow.flowId) revert ManagerFlowIdMismatch(_flow.flowId, computed);
    }
}
