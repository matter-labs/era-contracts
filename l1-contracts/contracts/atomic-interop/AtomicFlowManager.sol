// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAtomicFlowManager} from "./IAtomicFlowManager.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {LegState, ImtNonInclusionProof, AtomicFinalityProof} from "./IAtomicInterop.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {InteropBundle, InteropCall} from "../common/Messaging.sol";
import {InteropDataEncoding} from "../interop/InteropDataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
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
    ManagerChainsNotSorted,
    ManagerProofCountMismatch,
    ManagerExecutingBundleNotInFlow,
    ManagerNoRecoverableCalls
} from "./AtomicInteropErrors.sol";

/// @dev Local view of `AssetRouterBase.finalizeDeposit` (declared on the base, not the interface) so
/// the manager can recognise and decode the destination mint call embedded in a bundle.
interface IAssetRouterFinalizeDeposit {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;
}

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
/// reversing the bundle's asset-router calls via `L2AssetRouter.recoverAtomicBurn`.
///
/// Mutual exclusivity (no double-spend): an `executeAtomicBundle` requires every leg present in a root
/// settled at SL block `<= deadline`, while a `claimRefund` requires some leg absent in a root settled
/// at SL block `> deadline`. Because the per-chain IMTs are append-only, those cannot both hold.
contract AtomicFlowManager is IAtomicFlowManager {
    /// @dev `finalizeDeposit(uint256,bytes32,bytes)` — the selector of the destination mint call that
    /// `initiateIndirectCall` embeds in an interop bundle (see `AssetRouterBase.getDepositCalldata`).
    bytes4 internal constant FINALIZE_DEPOSIT_SELECTOR = IAssetRouterFinalizeDeposit.finalizeDeposit.selector;

    /// @dev (flowId, bundleHash) => source-leg state on this chain. All collaborators
    /// (commitment tree, asset router, interop center, interop handler) are genesis-deployed built-ins
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
        _checkFlowId(_finality.flowId, _finality.legBundleHashes, _finality.chainIds, _finality.deadline);

        uint256 n = _finality.legBundleHashes.length;
        if (_finality.proofs.length != n) revert ManagerProofCountMismatch(n, _finality.proofs.length);

        // Every leg must be present in its source chain's IMT as of a root settled no later than the
        // deadline. The membership check binds each leg to the chain whose imported interop root
        // authenticated it — a leg's `bundleHash` bakes in its `sourceChainId`, so it can only be
        // included in that chain's tree.
        bool executingIsLeg = false;
        for (uint256 i = 0; i < n; ++i) {
            if (_finality.legBundleHashes[i] == _executingBundleHash) executingIsLeg = true;
            uint256 value = AtomicInteropProof.commitValue(_finality.flowId, _finality.legBundleHashes[i]);
            AtomicInteropProof.verifyInclusion(_finality.proofs[i], value, _finality.deadline);
        }
        if (!executingIsLeg) revert ManagerExecutingBundleNotInFlow(_finality.flowId, _executingBundleHash);
    }

    /// @inheritdoc IAtomicFlowManager
    function authorizeRefund(
        bytes32 _flowId,
        bytes32[] calldata _legBundleHashes,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingLegIndex,
        ImtNonInclusionProof calldata _proof
    ) external {
        _checkFlowId(_flowId, _legBundleHashes, _chainIds, _deadline);

        // 1. Prove a leg is absent past the deadline -> the flow can no longer finalize.
        uint256 value = AtomicInteropProof.commitValue(_flowId, _legBundleHashes[_missingLegIndex]);
        AtomicInteropProof.verifyNonInclusion(_proof, value, _deadline);

        // 2. Mark this chain's committed source legs Revertable (legs committed on other chains are not
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
        // Effects before interactions.
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
    function assetRouter() public view virtual returns (address) {
        return L2_ASSET_ROUTER_ADDR;
    }

    /// @inheritdoc IAtomicFlowManager
    function interopCenter() public view virtual returns (address) {
        return L2_INTEROP_CENTER_ADDR;
    }

    /// @inheritdoc IAtomicFlowManager
    function interopHandler() public view virtual returns (address) {
        return L2_INTEROP_HANDLER_ADDR;
    }

    /// @dev Reverses every asset-router burn embedded in `_bundle`, re-minting each asset to its
    /// depositor (the burn's `originalCaller`). Each destination mint call the source bundle carries
    /// was `finalizeDeposit(sourceChainId, assetId, bridgeMintData)`; we recover the same
    /// `(assetId, amount)` against the burn's destination chain via `recoverAtomicBurn`, swapping the
    /// receiver to the depositor. Reverts if the bundle carries no such call.
    // TODO(atomic-interop): clean this up. It reaches into the asset-router's deposit wire format —
    // sniffing the `finalizeDeposit` selector via inline assembly, hand-stripping the selector
    // byte-by-byte (`_decodeFinalizeDeposit`), and re-decoding/re-encoding `bridgeMintData` just to swap
    // the receiver to the depositor. This duplicates AR encoding knowledge and is fragile to layout
    // changes. The recovery-data construction should live in (or be delegated to) the asset router.
    function _recoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) internal {
        uint256 destChainId = _bundle.destinationChainId;
        uint256 callsLen = _bundle.calls.length;
        uint256 recovered = 0;
        for (uint256 i = 0; i < callsLen; ++i) {
            InteropCall memory c = _bundle.calls[i];
            if (c.to != L2_ASSET_ROUTER_ADDR) continue;
            bytes memory cd = c.data;
            if (cd.length < 4) continue;
            bytes4 selector;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                selector := mload(add(cd, 0x20))
            }
            if (selector != FINALIZE_DEPOSIT_SELECTOR) continue;

            // Decode finalizeDeposit(sourceChainId, assetId, bridgeMintData) and re-mint to depositor.
            (bytes32 assetId, bytes memory mintData) = _decodeFinalizeDeposit(cd);
            // slither-disable-next-line unused-return
            (address depositor, , address originToken, uint256 amount, bytes memory erc20Metadata) = DataEncoding
                .decodeBridgeMintData(mintData);
            bytes memory recoverData = DataEncoding.encodeBridgeMintData({
                _originalCaller: depositor,
                _remoteReceiver: depositor,
                _originToken: originToken,
                _amount: amount,
                _erc20Metadata: erc20Metadata
            });
            IL2AssetRouter(assetRouter()).recoverAtomicBurn(destChainId, assetId, recoverData);
            ++recovered;
        }
        if (recovered == 0) revert ManagerNoRecoverableCalls(_flowId, _bundleHash);
    }

    /// @dev Strips the 4-byte selector from a `finalizeDeposit(uint256,bytes32,bytes)` calldata blob and
    /// returns `(assetId, bridgeMintData)`. The source chain id (first arg) is not needed for recovery.
    function _decodeFinalizeDeposit(
        bytes memory _callData
    ) private pure returns (bytes32 assetId, bytes memory mintData) {
        uint256 argsLen = _callData.length - 4;
        bytes memory args = new bytes(argsLen);
        for (uint256 i = 0; i < argsLen; ++i) {
            args[i] = _callData[i + 4];
        }
        // slither-disable-next-line unused-return
        (, assetId, mintData) = abi.decode(args, (uint256, bytes32, bytes));
    }

    /// @dev Recomputes `flowId` and asserts it matches, enforcing strictly-ascending `_legBundleHashes`
    /// and `_chainIds`.
    function _checkFlowId(
        bytes32 _flowId,
        bytes32[] calldata _legBundleHashes,
        uint256[] calldata _chainIds,
        uint64 _deadline
    ) internal pure {
        uint256 n = _legBundleHashes.length;
        for (uint256 i = 1; i < n; ++i) {
            if (_legBundleHashes[i] <= _legBundleHashes[i - 1]) revert ManagerBundleHashesNotSorted();
        }
        uint256 m = _chainIds.length;
        for (uint256 i = 1; i < m; ++i) {
            if (_chainIds[i] <= _chainIds[i - 1]) revert ManagerChainsNotSorted();
        }
        bytes32 computed = keccak256(abi.encode(_legBundleHashes, _chainIds, _deadline));
        if (computed != _flowId) revert ManagerFlowIdMismatch(_flowId, computed);
    }
}
