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
    ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY,
    ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
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
import {IL2Bridgehub} from "../core/bridgehub/IL2Bridgehub.sol";
import {
    ManagerAcceptedBundleNotInFlow,
    ManagerAcceptedLegDestinationChainMismatch,
    ManagerAlreadyInitialized,
    ManagerL1ChainIdZero,
    ManagerNotInteropCenter,
    ManagerNotInteropHandler,
    ManagerLegAlreadyAccepted,
    ManagerLegAlreadyCommitted,
    ManagerLegNotRevertable,
    ManagerFlowDeadlinePassed,
    ManagerFlowIdMismatch,
    ManagerFlowPreimageVersionMismatch,
    ManagerBundleHashesNotSorted,
    ManagerCommittedBundleNotInFlow,
    ManagerCommittedLegDestinationChainMismatch,
    ManagerCommittedLegSourceChainMismatch,
    ManagerLegChainNotAllowed,
    ManagerLegChainNotRegistered,
    ManagerTooManyLegs,
    ManagerLegChainIdsLengthMismatch,
    ManagerMissingLegIndexOutOfRange,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerSettlementLayerNotL1,
    ProofSourceChainMismatch
} from "./AtomicInteropErrors.sol";
import {RecoverToL1NotSupported, Unauthorized} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowManager}. Coordinates atomic interop flows on this chain (send-side commit,
/// destination-side acceptance, per-chain participation, finality gate, timeout refund); it never custodies funds. See {protocol-docs/atomicity/flow.md#the-atomicflowmanager};
/// the exact finalization/timeout conditions live in the {AtomicInteropProof} library header.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev (flowId, bundleHash) => source-leg state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 bundleHash => LegState)) internal _state;

    /// @dev The L1 chain ID, set once in `initL2`; every flow's `settlementLayerChainId` must equal it
    /// (atomic interop is L1-settling only in this release).
    uint256 public L1_CHAIN_ID;

    /// @dev (flowId, bundleHash) => whether this chain, as the leg's destination, accepted it.
    mapping(bytes32 flowId => mapping(bytes32 bundleHash => bool accepted)) internal _accepted;

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
        uint256 _destinationChainId,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external onlyInteropCenter {
        bytes32 flowId = _validateAndComputeFlowId(_flowPreimage);
        _checkSettlementLayerIsL1(_flowPreimage.settlementLayerChainId);
        _checkDeadlineNotPassed(_flowPreimage);

        // The committing bundle must be one of the flow's legs, declared with this chain as its source
        // (see {AtomicFlowPreimage}).
        uint256 n = _flowPreimage.legBundleHashes.length;
        uint256 legIndex = _legIndex(_flowPreimage, _bundleHash);
        if (legIndex == n) {
            revert ManagerCommittedBundleNotInFlow(flowId, _bundleHash);
        }
        if (_flowPreimage.legChainIds[legIndex] != block.chainid) {
            revert ManagerCommittedLegSourceChainMismatch(flowId, block.chainid, _flowPreimage.legChainIds[legIndex]);
        }
        // A wrong declared destination could never accept the leg, so the flow would only time out.
        if (_flowPreimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED) {
            uint256 declaredDestinationChainId = _flowPreimage.legChainIds[n + legIndex];
            if (declaredDestinationChainId != _destinationChainId) {
                revert ManagerCommittedLegDestinationChainMismatch(
                    flowId,
                    _destinationChainId,
                    declaredDestinationChainId
                );
            }
        }

        _checkLegChainsRegistered(_flowPreimage);

        if (_state[flowId][_bundleHash] != LegState.Unset) {
            revert ManagerLegAlreadyCommitted(flowId, _bundleHash);
        }
        // Effects before interaction: mark committed before touching the tree.
        _state[flowId][_bundleHash] = LegState.Committed;

        if (_flowPreimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED) {
            emit FlowLegCommitted(flowId, _bundleHash);
            _participateIfComplete(flowId, _flowPreimage, _lowNullifierIndex);
            return;
        }

        uint256 value = AtomicInteropProof.commitValue(flowId, _bundleHash);
        // slither-disable-next-line unused-return
        (uint256 index, ) = IL2InteropCommitmentTree(commitmentTree()).insert(value, _lowNullifierIndex);

        emit FlowCommitted(flowId, _bundleHash, _flowPreimage.deadline, index);
    }

    /// @inheritdoc IAtomicFlowManager
    function accept(
        bytes32 _bundleHash,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage calldata _flowPreimage
    ) external onlyInteropHandler {
        bytes32 flowId = _validateAndComputeFlowId(_flowPreimage);
        if (_flowPreimage.version != ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED) {
            revert ManagerFlowPreimageVersionMismatch(ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED, _flowPreimage.version);
        }
        _checkSettlementLayerIsL1(_flowPreimage.settlementLayerChainId);
        _checkDeadlineNotPassed(_flowPreimage);

        uint256 n = _flowPreimage.legBundleHashes.length;
        uint256 legIndex = _legIndex(_flowPreimage, _bundleHash);
        if (legIndex == n) {
            revert ManagerAcceptedBundleNotInFlow(flowId, _bundleHash);
        }
        uint256 declaredDestinationChainId = _flowPreimage.legChainIds[n + legIndex];
        if (declaredDestinationChainId != block.chainid) {
            revert ManagerAcceptedLegDestinationChainMismatch(flowId, block.chainid, declaredDestinationChainId);
        }

        // Accept only a flow this chain could execute: every chain whose tree the finality proof reads
        // must be registered and accepted by this chain's receive filter.
        _checkLegChainsRegistered(_flowPreimage);
        uint256 m = _flowPreimage.legChainIds.length;
        for (uint256 i = 0; i < m; ++i) {
            _checkLegChainAllowed(_flowPreimage.legChainIds[i]);
        }

        if (_accepted[flowId][_bundleHash]) {
            revert ManagerLegAlreadyAccepted(flowId, _bundleHash);
        }
        _accepted[flowId][_bundleHash] = true;
        emit FlowAccepted(flowId, _bundleHash);

        _participateIfComplete(flowId, _flowPreimage, _lowNullifierIndex);
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

        (uint256[] memory chainIds, uint256[] memory values) = _finalityCommitments(flow.flowId, preimage);
        uint256 m = chainIds.length;
        if (_finality.proofs.length != m) {
            revert ManagerProofCountMismatch(m, _finality.proofs.length);
        }

        // Every commitment must satisfy the finality condition (see the {AtomicInteropProof} library
        // header). The per-proof chain check is defense-in-depth here (inclusion self-binds via the
        // chain-specific value) but load-bearing on the symmetric refund path.
        uint256 n = preimage.legBundleHashes.length;
        bool executingIsLeg = false;
        for (uint256 i = 0; i < n; ++i) {
            if (preimage.legBundleHashes[i] == _executingBundleHash) {
                executingIsLeg = true;
                break;
            }
        }
        for (uint256 j = 0; j < m; ++j) {
            if (_finality.proofs[j].sourceChainId != chainIds[j]) {
                revert ProofSourceChainMismatch(chainIds[j], _finality.proofs[j].sourceChainId);
            }
            _checkLegChainAllowed(chainIds[j]);
            AtomicInteropProof.verifyInclusion(
                _finality.proofs[j],
                values[j],
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

        // Bind the absence proof to the chain declared at the index: a commitment value is trivially
        // absent from any OTHER chain's tree, so an unbound proof would allow a double-mint refund of a
        // finalized flow. See {protocol-docs/atomicity/proofs.md#timeout}.
        AtomicFlowPreimage calldata preimage = _flow.preimage;
        if (_missingLegIndex >= preimage.legChainIds.length) {
            revert ManagerMissingLegIndexOutOfRange(preimage.legChainIds.length, _missingLegIndex);
        }
        uint256 missingLegChainId = preimage.legChainIds[_missingLegIndex];
        if (_absence.sourceChainId != missingLegChainId) {
            revert ProofSourceChainMismatch(missingLegChainId, _absence.sourceChainId);
        }
        _checkLegChainAllowed(missingLegChainId);

        AtomicInteropProof.verifyTimeoutAbsence(
            _absence,
            _commitmentValue(_flow.flowId, preimage, _missingLegIndex),
            preimage.deadline,
            preimage.settlementLayerChainId
        );

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
    function legAccepted(bytes32 _flowId, bytes32 _bundleHash) external view returns (bool) {
        return _accepted[_flowId][_bundleHash];
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
    /// Dispatch rationale and the two mechanisms:
    /// {protocol-docs/atomicity/recovery.md#_recoverbundle-reversing-the-burns}.
    /// @dev A bundle where no call is recoverable has no source funds to return: the refund then simply
    /// flips the leg to `Reverted` without moving anything — the state transition must not be blocked.
    function _recoverBundle(InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        // L2->L1 atomic bundles are rejected at send time ({InteropCenter.AtomicBundleToL1NotSupported}), so a
        // recovered bundle never targets L1. Assert it explicitly: this keeps recovery from ever reaching the
        // append-only L1 deposit/withdrawal counters in {L2AssetTracker}, whose settlement-layer-conditional
        // updates are only correct when evaluated at send time, not at recovery time. Mirrors the same guard on
        // the base-token recovery path ({L2AssetTracker.assertRecoveryIsAccountingNeutral}).
        require(destChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        bytes32 destBaseTokenAssetId = _bundle.destinationBaseTokenAssetId;
        uint256 callsLen = _bundle.calls.length;
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            // Indirect calls are restricted to the asset router at send (`IndirectCallOnlyToAssetRouter`),
            // so `from == L2_ASSET_ROUTER_ADDR` selects the burn-producing indirect calls (assuming the
            // router never itself initiates a direct send — true today), and any other `from` is a
            // direct call's sender (possibly an EOA, which must not be probed — the revert would take
            // down the whole claim); its `value`, if any, is handled below. The
            // sender reports via the return value whether it recognised (and reversed) the call; nothing
            // is done with the answer — an unrecognised call simply has nothing to recover (see known
            // issue 1 in {protocol-docs/atomicity/security.md#known-issues-to-be-fixed-in-this-release}).
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

    /// @dev Reject a commitment to a flow whose deadline has verifiably passed: an imported settlement-layer
    /// root created after the deadline is exactly what `authorizeRefund` needs, so committing now could only
    /// lock funds into a flow that must be refunded. As an expired-flow guard this is BEST EFFORT only —
    /// imported roots lag the settlement layer's clock, and other chains have their own views. What it
    /// enforces unconditionally is ordering on this chain: reverting a leg requires importing a root with
    /// `timestamp > deadline` (see {AtomicInteropProof.verifyTimeoutAbsence}) and the tracked timestamp is a
    /// monotone maximum, so once a leg of the flow was reverted here, no new commitment can be made here.
    function _checkDeadlineNotPassed(AtomicFlowPreimage calldata _flowPreimage) internal view {
        uint256 latestImportedRootTimestamp = L2_INTEROP_ROOT_STORAGE.latestInteropRootTimestamp(
            _flowPreimage.settlementLayerChainId
        );
        if (latestImportedRootTimestamp > _flowPreimage.deadline) {
            revert ManagerFlowDeadlinePassed(_flowPreimage.deadline, latestImportedRootTimestamp);
        }
    }

    /// @dev Every chain whose tree holds a commitment of the flow must be Bridgehub-registered: registration
    /// guarantees MessageRoot presence, without which the commitment could never be proven present OR absent
    /// and the whole flow would be stranded. See
    /// {protocol-docs/atomicity/security.md#timeout-protocol-preconditions}.
    function _checkLegChainsRegistered(AtomicFlowPreimage calldata _flowPreimage) internal view {
        uint256 m = _flowPreimage.legChainIds.length;
        for (uint256 i = 0; i < m; ++i) {
            uint256 legChainId = _flowPreimage.legChainIds[i];
            if (legChainId == block.chainid) {
                continue;
            }
            if (L2_BRIDGEHUB.baseTokenAssetId(legChainId) == bytes32(0)) {
                revert ManagerLegChainNotRegistered(legChainId);
            }
        }
    }

    /// @dev Index of `_bundleHash` in the strictly ascending `legBundleHashes`, or its length if absent.
    function _legIndex(AtomicFlowPreimage calldata _flowPreimage, bytes32 _bundleHash) internal pure returns (uint256) {
        uint256 n = _flowPreimage.legBundleHashes.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_flowPreimage.legBundleHashes[i] == _bundleHash) {
                return i;
            }
        }
        return n;
    }

    /// @dev The IMT value that `legChainIds[_index]` must hold for the flow: leg `_index`'s commit value in a
    /// source-only flow, or that chain's participation value in an accepted flow.
    function _commitmentValue(
        bytes32 _flowId,
        AtomicFlowPreimage calldata _preimage,
        uint256 _index
    ) internal pure returns (uint256) {
        if (_preimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY) {
            return AtomicInteropProof.commitValue(_flowId, _preimage.legBundleHashes[_index]);
        }
        return AtomicInteropProof.participationValue(_flowId, _preimage.legChainIds[_index]);
    }

    /// @dev The commitments finality proves, in proof order (see {AtomicFinalityProof.proofs}): each leg's commit
    /// on its source for a source-only flow, or each distinct chain's participation, in order of first
    /// appearance in `legChainIds`, for an accepted flow.
    function _finalityCommitments(
        bytes32 _flowId,
        AtomicFlowPreimage calldata _preimage
    ) internal pure returns (uint256[] memory chainIds, uint256[] memory values) {
        uint256 m = _preimage.legChainIds.length;
        chainIds = new uint256[](m);
        values = new uint256[](m);
        uint256 count = 0;
        for (uint256 i = 0; i < m; ++i) {
            uint256 chainId = _preimage.legChainIds[i];
            if (_preimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED && _isListed(chainIds, count, chainId)) {
                continue;
            }
            chainIds[count] = chainId;
            values[count] = _commitmentValue(_flowId, _preimage, i);
            ++count;
        }
        assembly ("memory-safe") {
            mstore(chainIds, count)
            mstore(values, count)
        }
    }

    /// @dev Whether `_chainId` is among the first `_count` entries of `_chainIds`.
    function _isListed(uint256[] memory _chainIds, uint256 _count, uint256 _chainId) internal pure returns (bool) {
        for (uint256 i = 0; i < _count; ++i) {
            if (_chainIds[i] == _chainId) {
                return true;
            }
        }
        return false;
    }

    /// @dev Inserts this chain's participation value once every leg the preimage declares from this chain is
    /// committed and every leg declared to it is accepted. Called after each such step, so the last one inserts.
    function _participateIfComplete(
        bytes32 _flowId,
        AtomicFlowPreimage calldata _flowPreimage,
        uint256 _lowNullifierIndex
    ) internal {
        uint256 n = _flowPreimage.legBundleHashes.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 leg = _flowPreimage.legBundleHashes[i];
            if (_flowPreimage.legChainIds[i] == block.chainid && _state[_flowId][leg] == LegState.Unset) {
                return;
            }
            if (_flowPreimage.legChainIds[n + i] == block.chainid && !_accepted[_flowId][leg]) {
                return;
            }
        }

        uint256 value = AtomicInteropProof.participationValue(_flowId, block.chainid);
        // slither-disable-next-line unused-return
        (uint256 index, ) = IL2InteropCommitmentTree(commitmentTree()).insert(value, _lowNullifierIndex);

        emit FlowParticipated(_flowId, _flowPreimage.deadline, index);
    }

    /// @dev Atomic interop is L1-settling only in this release (see {protocol-docs/atomicity/security.md#trust-assumptions});
    /// checked wherever the settlement layer is consumed: `append`, finality and refund verification.
    function _checkSettlementLayerIsL1(uint256 _settlementLayerChainId) internal view {
        if (_settlementLayerChainId != L1_CHAIN_ID) {
            revert ManagerSettlementLayerNotL1(L1_CHAIN_ID, _settlementLayerChainId);
        }
    }

    /// @notice Reverts unless this chain accepts interop from `_legChainId`: the chain itself, or a peer its
    /// admin allowed. See {protocol-docs/interop-gating.md#receive-filter}.
    /// @param _legChainId A chain whose IMT proof this chain is about to accept.
    function _checkLegChainAllowed(uint256 _legChainId) internal view {
        if (_legChainId != block.chainid && !IL2Bridgehub(address(L2_BRIDGEHUB)).isPeerAllowed(_legChainId)) {
            revert ManagerLegChainNotAllowed(_legChainId);
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
    /// `version` must be manager-supported ({ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY} or
    /// {ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}); `legBundleHashes` must be strictly ascending; `legChainIds`
    /// is positional (may repeat — a set would let a sibling chain in it enable a wrong-chain refund), so only
    /// its length is checked: one entry per leg, or two for an accepted flow.
    /// Shared by the send path (`append`) and `_checkFlowId`, so canonicalization cannot drift.
    function _validateAndComputeFlowId(AtomicFlowPreimage calldata _preimage) internal pure returns (bytes32) {
        uint256 chainIdsPerLeg;
        if (_preimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY) {
            chainIdsPerLeg = 1;
        } else if (_preimage.version == ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED) {
            chainIdsPerLeg = 2;
        } else {
            revert ManagerFlowPreimageVersionMismatch(ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED, _preimage.version);
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
        if (_preimage.legChainIds.length != chainIdsPerLeg * n) {
            revert ManagerLegChainIdsLengthMismatch(chainIdsPerLeg * n, _preimage.legChainIds.length);
        }
        return keccak256(abi.encode(_preimage));
    }
}
