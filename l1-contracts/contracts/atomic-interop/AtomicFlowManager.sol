// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAtomicFlowManager} from "./IAtomicFlowManager.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IAtomicRecoverable} from "./IAtomicRecoverable.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {
    LegState,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    AtomicFinalityProof,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "./IAtomicInterop.sol";
import {InteropBundle, InteropCall} from "../common/Messaging.sol";
import {InteropDataEncoding} from "../interop/InteropDataEncoding.sol";
import {IAssetRouterShared} from "../bridge/asset-router/IAssetRouterShared.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2_BRIDGEHUB} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {
    ManagerAlreadyInitialized,
    ManagerL1ChainIdZero,
    ManagerNotInteropCenter,
    ManagerNotInteropHandler,
    ManagerLegAlreadyCommitted,
    ManagerLegNotRevertable,
    ManagerFlowIdMismatch,
    ManagerFlowPreimageVersionMismatch,
    ManagerBundleHashesNotSorted,
    ManagerCommittedBundleNotInFlow,
    ManagerCommittedLegSourceChainMismatch,
    ManagerLegSourceChainNotRegistered,
    ManagerLegSourceChainIdsLengthMismatch,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerNoRecoverableCalls,
    ManagerSettlementLayerNotL1,
    ProofSourceChainMismatch
} from "./AtomicInteropErrors.sol";
import {Unauthorized} from "../l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {RecoverToL1NotSupported} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowManager}. Fund-touchless coordinator for the atomic interop flow.
///
/// Send: {InteropCenter.sendBundle} burns through the normal `initiateIndirectCall` path, then — when
/// the bundle carries the `atomicBundle` attribute — calls {append} instead of publishing the bundle
/// to L1; `append` records the leg's commit value in this chain's {L2InteropCommitmentTree}.
/// Receive: {L2InteropHandler.executeAtomicBundle} calls {requireFlowFinalized} (the atomicity gate) in
/// place of the L1-message inclusion proof, then executes the bundle (and owns the replay guard).
/// Timeout: {authorizeRefund} + {claimRefund} recover the burned source funds to the depositor by
/// asking each burn-producing call's local sender to reverse itself via {IAtomicRecoverable.recoverAtomicCall}.
///
/// Finalization and refund cannot both succeed when their proofs use the leg's declared source chain
/// and the flow's settlement layer. Both values are included in `flowId`. Without the source-chain
/// check, an attacker could finalize using a valid commitment on the real source chain, then obtain a
/// refund by proving that the same value is absent from an unrelated chain. See {AtomicInteropProof}
/// for the full finalization and timeout conditions.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev (flowId, bundleHash) => source-leg state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 bundleHash => LegState)) internal _state;

    /// @dev The chain ID of the L1 network, set during the genesis upgrade (see `initL2`). In this
    /// release interop legs settle on L1 only, so every flow's `settlementLayerChainId` must equal it.
    uint256 public L1_CHAIN_ID;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice One-time L2 initialization performed by the genesis upgrade.
    /// @param _l1ChainId The chain ID of the L1 network.
    function initL2(uint256 _l1ChainId) external onlyUpgrader {
        if (L1_CHAIN_ID != 0) {
            revert ManagerAlreadyInitialized();
        }
        // `L1_CHAIN_ID == 0` is the sentinel for "not initialized"; a zero argument would leave the manager
        // permanently re-initializable and defeat that guard.
        if (_l1ChainId == 0) {
            revert ManagerL1ChainIdZero();
        }
        L1_CHAIN_ID = _l1ChainId;
    }

    modifier onlyInteropCenter() {
        if (msg.sender != interopCenter()) {
            revert ManagerNotInteropCenter(msg.sender);
        }
        _;
    }

    modifier onlyInteropHandler() {
        if (msg.sender != interopHandler()) {
            revert ManagerNotInteropHandler(msg.sender);
        }
        _;
    }

    /// @inheritdoc IAtomicFlowManager
    function append(
        bytes32 _bundleHash,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external onlyInteropCenter {
        // The checks shared with the finalize/refund paths (preimage shape, then settlement layer) run
        // in the same order here, so a preimage all paths reject reverts with the same reason on each
        // of them. The send-only coupling checks (bundle-is-a-leg, source-is-this-chain) follow below.
        bytes32 flowId = _validateAndComputeFlowId(_flowPreimage);
        // A flow with a non-L1 settlement layer could neither finalize nor refund (both proof paths
        // enforce SL == L1), so reject it before committing anything.
        _checkSettlementLayerIsL1(_flowPreimage.settlementLayerChainId);

        // The committing bundle must be one of the flow's legs, declared with this chain as its
        // source. This is the coupling guarantee the preimage exists for: a bundle can never be
        // committed under a `flowId` that does not contain it (see {AtomicFlowPreimage}).
        // `legBundleHashes` is strictly ascending (checked above), so `_bundleHash` occurs at most once.
        uint256 n = _flowPreimage.legBundleHashes.length;
        uint256 legIndex = n;
        for (uint256 i = 0; i < n; ++i) {
            if (_flowPreimage.legBundleHashes[i] == _bundleHash) {
                legIndex = i;
                break;
            }
        }
        if (legIndex == n) {
            revert ManagerCommittedBundleNotInFlow(flowId, _bundleHash);
        }
        if (_flowPreimage.legSourceChainIds[legIndex] != block.chainid) {
            revert ManagerCommittedLegSourceChainMismatch(
                flowId,
                block.chainid,
                _flowPreimage.legSourceChainIds[legIndex]
            );
        }

        // Every other leg's declared source must be an interop-registered chain (this chain is always
        // acceptable — its legs are validated by the coupling check above when committed). Registration
        // implies presence in the settlement layer's MessageRoot (`ChainRegistrationSender` gates on
        // `chainTreeLeafCount > 0`, fresh chains are genesis-seeded), which the refund path requires:
        // the absence proof is bound to the missing leg's declared source chain, so a leg declaring a
        // chain with no MessageRoot presence could never be proven absent (nor, being fabricated,
        // committed) and every committed leg of the flow — including this one — would be stranded.
        // This also rejects L1 as a declared source (never registered as an interop chain here), which
        // matches send-side reality: interop bundles cannot be initiated on L1.
        for (uint256 i = 0; i < n; ++i) {
            uint256 legSourceChainId = _flowPreimage.legSourceChainIds[i];
            if (legSourceChainId == block.chainid) {
                continue;
            }
            if (L2_BRIDGEHUB.baseTokenAssetId(legSourceChainId) == bytes32(0)) {
                revert ManagerLegSourceChainNotRegistered(legSourceChainId);
            }
        }

        if (_state[flowId][_bundleHash] != LegState.Unset) {
            revert ManagerLegAlreadyCommitted(flowId, _bundleHash);
        }
        // Effects before interaction: mark committed before touching the tree.
        _state[flowId][_bundleHash] = LegState.Committed;

        uint256 value = AtomicInteropProof.commitValue(flowId, _bundleHash);
        // slither-disable-next-line unused-return
        (uint256 index, ) = IL2InteropCommitmentTree(commitmentTree()).insert(value, _lowNullifierIndex);

        emit FlowCommitted(flowId, _bundleHash, _flowPreimage.deadline, index);
    }

    /// @inheritdoc IAtomicFlowManager
    function requireFlowFinalized(
        bytes32 _executingBundleHash,
        AtomicFinalityProof calldata _finality
    ) external view onlyInteropHandler {
        AtomicFlow calldata flow = _finality.flow;
        AtomicFlowPreimage calldata preimage = flow.preimage;
        _checkFlowId(flow);
        _checkSettlementLayerIsL1(preimage.settlementLayerChainId);

        uint256 n = preimage.legBundleHashes.length;
        if (_finality.proofs.length != n) {
            revert ManagerProofCountMismatch(n, _finality.proofs.length);
        }

        // Every leg must satisfy the finality condition (see the {AtomicInteropProof} library
        // header). Each proof's `sourceChainId` must equal the leg's declared `legSourceChainIds[i]`:
        // defense-in-depth here (membership already self-binds via the chain-specific `commitValue`) but
        // load-bearing for the symmetric refund path. The proof's settlement layer must match the flow's
        // `settlementLayerChainId`, checked inside {AtomicInteropProof.verifyInclusion}.
        bool executingIsLeg = false;
        for (uint256 i = 0; i < n; ++i) {
            if (preimage.legBundleHashes[i] == _executingBundleHash) {
                executingIsLeg = true;
            }
            if (_finality.proofs[i].sourceChainId != preimage.legSourceChainIds[i]) {
                revert ProofSourceChainMismatch(preimage.legSourceChainIds[i], _finality.proofs[i].sourceChainId);
            }
            uint256 value = AtomicInteropProof.commitValue(flow.flowId, preimage.legBundleHashes[i]);
            AtomicInteropProof.verifyInclusion(
                _finality.proofs[i],
                value,
                preimage.deadline,
                preimage.settlementLayerChainId
            );
        }
        if (!executingIsLeg) {
            revert ManagerExecutingBundleNotInFlow(flow.flowId, _executingBundleHash);
        }
    }

    /// @inheritdoc IAtomicFlowManager
    function authorizeRefund(AtomicFlow calldata _flow, uint256 _missingLegIndex, ImtProof calldata _absence) external {
        _checkFlowId(_flow);
        _checkSettlementLayerIsL1(_flow.preimage.settlementLayerChainId);

        // 1. Bind the absence proof to the missing leg's declared source chain. Without this, the leg's
        //    commit value — which exists only in its own source chain's tree — is trivially absent from
        //    any other chain's tree, so an on-time, finalized leg could be force-refunded against an
        //    unrelated chain (double-mint).
        AtomicFlowPreimage calldata preimage = _flow.preimage;
        uint256 missingLegChainId = preimage.legSourceChainIds[_missingLegIndex];
        if (_absence.sourceChainId != missingLegChainId) {
            revert ProofSourceChainMismatch(missingLegChainId, _absence.sourceChainId);
        }

        // 2. Timeout: the leg's commit value is proven absent per the timeout protocol described in
        //    the {AtomicInteropProof} library header, which makes the absence equivalent to "the
        //    flow can never finalize".
        uint256 value = AtomicInteropProof.commitValue(_flow.flowId, preimage.legBundleHashes[_missingLegIndex]);
        AtomicInteropProof.verifyTimeoutAbsence(_absence, value, preimage.deadline, preimage.settlementLayerChainId);

        // 3. Mark this chain's committed source legs Revertable (legs committed on other chains are not
        //    in this manager's state, so they are skipped).
        uint256 n = preimage.legBundleHashes.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 h = preimage.legBundleHashes[i];
            if (_state[_flow.flowId][h] != LegState.Committed) {
                continue;
            }
            _state[_flow.flowId][h] = LegState.Revertable;
            emit FlowRefundAuthorized(_flow.flowId, h);
        }
    }

    /// @inheritdoc IAtomicFlowManager
    function claimRefund(bytes32 _flowId, bytes calldata _bundle) external {
        InteropBundle memory bundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(_bundle);

        LegState s = _state[_flowId][bundleHash];
        if (s != LegState.Revertable) {
            revert ManagerLegNotRevertable(_flowId, bundleHash, s);
        }
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
    /// Each call's local sender (`InteropCall.from`) owns its own reversal via
    /// {IAtomicRecoverable.recoverAtomicCall}: it is the contract that authorized (and burned for) the call
    /// on this chain, while the call's target (`InteropCall.to`) lives on the destination chain and need
    /// not even exist here. The manager is agnostic to the call/encoding format and simply forwards
    /// `(destinationChainId, data)`, counting the calls that report a recovery. Senders must return `false`
    /// (not revert) for calls they do not recognise.
    ///
    /// A second reversal applies to native base-token value. A call carrying `value` had that base token
    /// collected at send time (see {InteropCenter._ensureCorrectTotalValue}) — held by the {BaseTokenHolder}
    /// when the destination shares this chain's base token, or deposited via the asset router otherwise.
    /// For direct calls, the refund routes through the asset router/NTV recovery path so the existing
    /// base-token recovery accounting is reused, returning `value` to the call's `from` (the depositor).
    /// Router-produced calls (`from == asset router`) do not take this branch: they carry no base-token
    /// `value` (indirect calls force `interopCallValue == 0`); what they move is a bridged asset, which
    /// {IAtomicRecoverable.recoverAtomicCall} reverses directly (re-minting / unlocking that asset), not a
    /// separate base-token value. Every direct value leg counts as a recovery.
    ///
    /// Recovery is best-effort by design. An atomic bundle may mix fund-moving calls with calls that move no
    /// funds and have nothing to reverse (e.g. flipping a flag). The latter contribute nothing. We only
    /// require that *some* call recovered (`recovered != 0`): a bundle where nothing is recoverable has no
    /// source funds to return, so a refund would be a no-op and we reject it.
    ///
    /// Consequence: the protocol does not guarantee full refundability of an arbitrary bundle. A flow author
    /// must make any bespoke fund-moving leg that does not carry `value` recoverable; otherwise it would
    /// strand its funds. L1-destined atomic bundles remain blocked at send time because L2->L1 withdrawals
    /// are never revertable.
    ///
    /// Scope: this is the atomicity (TIMEOUT) refund — it fires only when the flow is proven unable to
    /// finalize (a leg's commit value is still absent past the deadline, established via {authorizeRefund}).
    /// It is NOT a refund for cancelled or undeliverable calls: once a flow HAS finalized, a call that
    /// reverts on delivery (e.g. a non-{IERC7786Recipient} target) or that is cancelled during unbundle
    /// forfeits its value — unchanged from prior interop, where a finalized call to a reverting recipient
    /// was likewise un-executable and un-refundable. Extending refundability to those cases is possible
    /// future work.
    function _recoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        // L2->L1 atomic bundles are rejected at send time ({InteropCenter.AtomicBundleToL1NotSupported}), so a
        // recovered bundle never targets L1. Assert it explicitly: this keeps recovery from ever reaching the
        // append-only L1 deposit/withdrawal counters in {L2AssetTracker}, whose settlement-layer-conditional
        // updates are only correct when evaluated at send time, not at recovery time. Mirrors the same guard on
        // the base-token recovery path ({L2AssetTracker.handleRecoverBaseTokenBridgingOnL2}).
        require(destChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        bytes32 destBaseTokenAssetId = _bundle.destinationBaseTokenAssetId;
        uint256 callsLen = _bundle.calls.length;
        uint256 recovered = 0;
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            // Only ask burn-producing calls (from == asset router, as set by `initiateIndirectCall`) to
            // reverse themselves. A direct call never burned through a recoverable sender, so its `from`
            // (possibly an EOA) is skipped here; any base-token value it carried is handled below.
            if (c.from == L2_ASSET_ROUTER_ADDR) {
                if (IAtomicRecoverable(c.from).recoverAtomicCall(destChainId, c.data)) {
                    ++recovered;
                }
            }
            if (c.from != L2_ASSET_ROUTER_ADDR && c.value != 0) {
                IAssetRouterShared(L2_ASSET_ROUTER_ADDR).bridgehubRecoverBaseToken(
                    destChainId,
                    destBaseTokenAssetId,
                    c.from,
                    c.value
                );
                ++recovered;
            }
        }
        if (recovered == 0) {
            revert ManagerNoRecoverableCalls(_flowId, _bundleHash);
        }
    }

    /// @dev In this release interop operates against roots imported from L1 only (see
    /// `ChainAssetHandlerBase` — only the L1 message root is assumed for interop), so every flow must
    /// declare L1 as its settlement layer. Checked wherever the settlement layer is consumed: at
    /// send time (`append`, which receives the full flowId preimage) and at finality and refund
    /// verification.
    function _checkSettlementLayerIsL1(uint256 _settlementLayerChainId) internal view {
        if (_settlementLayerChainId != L1_CHAIN_ID) {
            revert ManagerSettlementLayerNotL1(L1_CHAIN_ID, _settlementLayerChainId);
        }
    }

    /// @dev Recomputes `flowId` from the flow's embedded preimage (see {_validateAndComputeFlowId})
    /// and asserts it matches `_flow.flowId`.
    function _checkFlowId(AtomicFlow calldata _flow) internal pure {
        bytes32 computed = _validateAndComputeFlowId(_flow.preimage);
        if (computed != _flow.flowId) {
            revert ManagerFlowIdMismatch(_flow.flowId, computed);
        }
    }

    /// @dev Canonicalizes and hashes a flowId preimage:
    /// `flowId = keccak256(abi.encode(preimage))`.
    /// `version` must be a manager-supported version (see {ATOMIC_FLOW_PREIMAGE_VERSION}).
    /// `legBundleHashes` must be strictly ascending (canonical order + dedup). `legSourceChainIds` is
    /// positional, aligned 1:1 with `legBundleHashes`; it may repeat and need not be ascending, so only its
    /// length is checked. Treating it as an ascending set instead would let a sibling chain in the set
    /// still enable a wrong-chain refund. The single implementation is shared by the send path (`append`)
    /// and the finalize/refund paths (`_checkFlowId`), so the preimage canonicalization cannot drift
    /// between them.
    function _validateAndComputeFlowId(AtomicFlowPreimage calldata _preimage) internal pure returns (bytes32) {
        if (_preimage.version != ATOMIC_FLOW_PREIMAGE_VERSION) {
            revert ManagerFlowPreimageVersionMismatch(ATOMIC_FLOW_PREIMAGE_VERSION, _preimage.version);
        }
        uint256 n = _preimage.legBundleHashes.length;
        for (uint256 i = 1; i < n; ++i) {
            if (_preimage.legBundleHashes[i] <= _preimage.legBundleHashes[i - 1]) {
                revert ManagerBundleHashesNotSorted();
            }
        }
        if (_preimage.legSourceChainIds.length != n) {
            revert ManagerLegSourceChainIdsLengthMismatch(n, _preimage.legSourceChainIds.length);
        }
        return keccak256(abi.encode(_preimage));
    }
}
