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
    ATOMIC_FLOW_PREIMAGE_VERSION,
    MAX_ATOMIC_FLOW_LEGS
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
import {L2_BRIDGEHUB, L2_INTEROP_ROOT_STORAGE} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {
    ManagerAlreadyInitialized,
    ManagerL1ChainIdZero,
    ManagerNotInteropCenter,
    ManagerNotInteropHandler,
    ManagerLegAlreadyCommitted,
    ManagerLegNotRevertable,
    ManagerFlowDeadlinePassed,
    ManagerFlowIdMismatch,
    ManagerFlowPreimageVersionMismatch,
    ManagerBundleHashesNotSorted,
    ManagerCommittedBundleNotInFlow,
    ManagerCommittedLegSourceChainMismatch,
    ManagerLegSourceChainNotRegistered,
    ManagerTooManyLegs,
    ManagerLegSourceChainIdsLengthMismatch,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerSettlementLayerNotL1,
    ProofSourceChainMismatch
} from "./AtomicInteropErrors.sol";
import {Unauthorized} from "../l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {RecoverToL1NotSupported} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowManager}. Coordinates atomic interop flows on this chain (send-side commit,
/// finality gate, timeout refund); it never custodies funds. See {protocol-docs/atomicity/flow.md#the-atomicflowmanager};
/// the exact finalization/timeout conditions live in the {AtomicInteropProof} library header.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev (flowId, bundleHash) => source-leg state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 bundleHash => LegState)) internal _state;

    /// @dev The L1 chain ID, set once in `initL2`; every flow's `settlementLayerChainId` must equal it
    /// (atomic interop is L1-settling only in this release).
    uint256 public L1_CHAIN_ID;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IAtomicFlowManager
    function initL2(uint256 _l1ChainId) external onlyUpgrader {
        if (L1_CHAIN_ID != 0) {
            revert ManagerAlreadyInitialized();
        }
        // Zero is the "not initialized" sentinel; a zero argument would leave the manager re-initializable.
        if (_l1ChainId == 0) {
            revert ManagerL1ChainIdZero();
        }
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @dev Only allows calls from the {InteropCenter}.
    modifier onlyInteropCenter() {
        if (msg.sender != interopCenter()) {
            revert ManagerNotInteropCenter(msg.sender);
        }
        _;
    }

    /// @dev Only allows calls from the {InteropHandler}.
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
        bytes32 flowId = _validateAndComputeFlowId(_flowPreimage);
        _checkSettlementLayerIsL1(_flowPreimage.settlementLayerChainId);

        // Reject a leg of a flow whose deadline has verifiably passed: an imported settlement-layer
        // root created after the deadline is exactly what `authorizeRefund` needs, so committing now
        // could only burn funds into a flow that must be refunded. As an expired-flow guard this is
        // BEST EFFORT only — imported roots lag the settlement layer's clock, and other source chains
        // have their own views. What it enforces unconditionally is ordering on this chain: reverting
        // a leg requires importing a root with `timestamp > deadline` (see
        // {AtomicInteropProof.verifyTimeoutAbsence}) and the tracked timestamp is a monotone maximum,
        // so once a leg of the flow was reverted here, no new leg can ever be committed here.
        uint256 latestImportedRootTimestamp = L2_INTEROP_ROOT_STORAGE.latestInteropRootTimestamp(
            _flowPreimage.settlementLayerChainId
        );
        if (latestImportedRootTimestamp > _flowPreimage.deadline) {
            revert ManagerFlowDeadlinePassed(_flowPreimage.deadline, latestImportedRootTimestamp);
        }

        // The committing bundle must be one of the flow's legs, declared with this chain as its source
        // (see {AtomicFlowPreimage}). `legBundleHashes` is strictly ascending (checked above), so
        // `_bundleHash` occurs at most once.
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

        // Every other leg must declare a Bridgehub-registered source chain: registration guarantees
        // MessageRoot presence, without which the leg could never be proven committed OR absent and the
        // whole flow would be stranded. See {protocol-docs/atomicity/security.md#timeout-protocol-preconditions}.
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

        // Every leg must satisfy the finality condition (see the {AtomicInteropProof} library header).
        // The per-proof source-chain check is defense-in-depth here (inclusion self-binds via the
        // chain-specific commit value) but load-bearing on the symmetric refund path.
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

        // Bind the absence proof to the missing leg's declared source chain: a commit value is trivially
        // absent from any OTHER chain's tree, so an unbound proof would allow a double-mint refund of a
        // finalized flow. See {protocol-docs/atomicity/proofs.md#timeout}.
        AtomicFlowPreimage calldata preimage = _flow.preimage;
        uint256 missingLegChainId = preimage.legSourceChainIds[_missingLegIndex];
        if (_absence.sourceChainId != missingLegChainId) {
            revert ProofSourceChainMismatch(missingLegChainId, _absence.sourceChainId);
        }

        uint256 value = AtomicInteropProof.commitValue(_flow.flowId, preimage.legBundleHashes[_missingLegIndex]);
        AtomicInteropProof.verifyTimeoutAbsence(_absence, value, preimage.deadline, preimage.settlementLayerChainId);

        // Mark this chain's committed source legs Revertable (legs committed on other chains are not
        // in this manager's state, so they are skipped).
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
        // No `nonReentrant` guard: CEI — the leg flips to `Reverted` before `_recoverBundle`'s external
        // calls, so a reentrant claim hits the `Revertable` check above. The manager never holds funds.
        _state[_flowId][bundleHash] = LegState.Reverted;

        _recoverBundle(bundle);

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

    /// @dev Reverses every recoverable call embedded in `_bundle` (best-effort timeout refund — see
    /// {protocol-docs/atomicity/recovery.md}), re-crediting the original depositor.
    /// @dev Each call's local sender (`InteropCall.from`) owns its own reversal via
    /// {IAtomicRecoverable.recoverAtomicCall}: the manager is agnostic to the call/encoding format and
    /// simply forwards `(destinationChainId, data)`. Senders MUST return `false` (not revert) for calls
    /// they do not recognise.
    /// @dev Native base-token `value` is reversed separately. Router-produced calls (`from == asset
    /// router`) never carry it (indirect calls force `interopCallValue == 0`) and take only the
    /// `recoverAtomicCall` branch. A direct call's `value` routes through the asset router/NTV base-token
    /// recovery path (reusing the existing accounting) back to its `from`.
    /// @dev A bundle where no call is recoverable has no source funds to return: the refund then simply
    /// flips the leg to `Reverted` without moving anything — the state transition must not be blocked.
    function _recoverBundle(InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        // L2->L1 atomic bundles are rejected at send time ({InteropCenter.AtomicBundleToL1NotSupported}), so a
        // recovered bundle never targets L1. Assert it explicitly: this keeps recovery from ever reaching the
        // append-only L1 deposit/withdrawal counters in {L2AssetTracker}, whose settlement-layer-conditional
        // updates are only correct when evaluated at send time, not at recovery time. Mirrors the same guard on
        // the base-token recovery path ({L2AssetTracker.handleRecoverBaseTokenBridgingOnL2}).
        require(destChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        bytes32 destBaseTokenAssetId = _bundle.destinationBaseTokenAssetId;
        uint256 callsLen = _bundle.calls.length;
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            // Only ask burn-producing calls (from == asset router, as set by `initiateIndirectCall`) to
            // reverse themselves. A direct call never burned through a recoverable sender, so its `from`
            // (possibly an EOA) is skipped here; any base-token value it carried is handled below.
            // The sender reports via the return value whether it recognised (and reversed) the call;
            // nothing is done with the answer — an unrecognised call simply has nothing to recover.
            if (c.from == L2_ASSET_ROUTER_ADDR) {
                // slither-disable-next-line unused-return
                IAtomicRecoverable(c.from).recoverAtomicCall(destChainId, c.data);
            }
            if (c.from != L2_ASSET_ROUTER_ADDR && c.value != 0) {
                IAssetRouterShared(L2_ASSET_ROUTER_ADDR).bridgehubRecoverBaseToken(
                    destChainId,
                    destBaseTokenAssetId,
                    c.from,
                    c.value
                );
            }
        }
    }

    /// @dev Atomic interop is L1-settling only in this release (see {protocol-docs/atomicity/security.md#trust-assumptions});
    /// checked wherever the settlement layer is consumed: `append`, finality and refund verification.
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

    /// @dev Canonicalizes and hashes a flowId preimage: `flowId = keccak256(abi.encode(preimage))`.
    /// `version` must be manager-supported (see {ATOMIC_FLOW_PREIMAGE_VERSION}); `legBundleHashes` must be
    /// strictly ascending; `legSourceChainIds` is positional (1:1, may repeat — a set would let a sibling
    /// chain in it enable a wrong-chain refund), so only its length is checked.
    /// Shared by the send path (`append`) and `_checkFlowId`, so canonicalization cannot drift.
    function _validateAndComputeFlowId(AtomicFlowPreimage calldata _preimage) internal pure returns (bytes32) {
        if (_preimage.version != ATOMIC_FLOW_PREIMAGE_VERSION) {
            revert ManagerFlowPreimageVersionMismatch(ATOMIC_FLOW_PREIMAGE_VERSION, _preimage.version);
        }
        uint256 n = _preimage.legBundleHashes.length;
        // See {MAX_ATOMIC_FLOW_LEGS}: appending a leg is cheap, but finalization verifies one Merkle
        // proof per leg, so the leg count must stay bounded.
        if (n > MAX_ATOMIC_FLOW_LEGS) {
            revert ManagerTooManyLegs(MAX_ATOMIC_FLOW_LEGS, n);
        }
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
