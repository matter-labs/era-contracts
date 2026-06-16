// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAtomicFlowEscrow} from "./IAtomicFlowEscrow.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {SendSpec, SpecState, ImtInclusionProof, ImtNonInclusionProof} from "./IAtomicInterop.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {
    EscrowAlreadyInitialized,
    EscrowChainsNotSorted,
    EscrowDepositorMismatch,
    EscrowFlowIdMismatch,
    EscrowInvalidAuthorizeFromState,
    EscrowInvalidRefundAuthorizeFromState,
    EscrowMissingProof,
    EscrowProofCountMismatch,
    EscrowSpecNotCommittedLocally,
    EscrowSelfDestination,
    EscrowSendSpecMissingDest,
    EscrowSendSpecZeroAmount,
    EscrowSendSpecZeroOriginChain,
    EscrowSendSpecZeroRecipient,
    EscrowSendSpecZeroToken,
    EscrowSpecAlreadyCommitted,
    EscrowSpecNotExecutable,
    EscrowSpecNotForThisChain,
    EscrowSpecNotRevertable,
    EscrowSpecsNotSorted
} from "./AtomicInteropErrors.sol";

/// @dev `finalizeDeposit` is declared on `AssetRouterBase` but not on its interface. Tiny local
/// interface so the escrow can call it without pulling in the abstract contract (mirrors L2FlowEscrow).
interface IAssetRouterFinalizeDeposit {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowEscrow}. Gated-burn / origin-recover atomic interop:
///   - `commitSend` burns (origin-native: locks) the depositor's tokens through AR/NTV immediately and
///     records the leg's commit value in this chain's {L2InteropCommitmentTree}. The source leg is
///     terminal at `Committed` — there is no source `execute`.
///   - `authorize` + `execute` mint a destination leg to its recipient once an IMT inclusion proof
///     shows the whole flow committed before the deadline.
///   - `authorizeRefund` + `claimRefund` recover the burned source funds to the depositor once an IMT
///     non-inclusion proof shows the flow timed out.
///
/// Mutual exclusivity (no double-spend): a destination `execute` requires every leg present in a
/// pre-deadline root, while a source `claimRefund` requires some leg absent in a post-deadline root.
/// Because the per-chain IMTs are append-only, those conditions cannot both hold for one flow.
contract AtomicFlowEscrow is IAtomicFlowEscrow {
    using SafeERC20 for IERC20;

    /// @dev The append-only indexed interop IMT (commitment tree) for this chain. Also the
    /// "initialized" flag.
    address internal _commitmentTree;
    /// @dev L2 asset router this escrow drives for burns / mints / recovery.
    address internal _assetRouter;
    /// @dev L2 native token vault used for source-side allowances.
    address internal _nativeTokenVault;

    /// @dev (flowId, specHash) => state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 specHash => SpecState)) internal _state;

    /// @notice One-shot initializer.
    /// @param _tree The {L2InteropCommitmentTree} this escrow inserts commit values into.
    /// @param _ar The L2 asset router this escrow drives for burns / mints / recovery.
    /// @param _ntv The L2 native token vault `_ar` routes through.
    function initialize(address _tree, address _ar, address _ntv) external {
        if (_commitmentTree != address(0)) revert EscrowAlreadyInitialized();
        _commitmentTree = _tree;
        _assetRouter = _ar;
        _nativeTokenVault = _ntv;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function commitSend(bytes32 _flowId, SendSpec calldata _spec, uint256 _lowNullifierIndex) external {
        _validateSourceSpec(_spec);
        if (msg.sender != _spec.depositor) revert EscrowDepositorMismatch(msg.sender, _spec.depositor);

        bytes32 specHash = keccak256(abi.encode(_spec));
        if (_state[_flowId][specHash] != SpecState.Unset) revert EscrowSpecAlreadyCommitted(specHash);
        // Effects before interactions: mark committed before pulling/burning funds or touching the tree.
        _state[_flowId][specHash] = SpecState.Committed;

        // Pull the depositor's tokens and burn (origin-native: lock) them through AR/NTV NOW — the
        // source "sends". Cross-chain settlement is gated by the destination's IMT inclusion proof; on
        // timeout the depositor recovers via `claimRefund` -> AR `recoverAtomicBurn`.
        IERC20(_spec.originToken).safeTransferFrom(_spec.depositor, address(this), _spec.amount);
        IERC20(_spec.originToken).safeIncreaseAllowance(_nativeTokenVault, _spec.amount);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory burnData = DataEncoding.encodeBridgeBurnData(_spec.amount, _spec.recipient, _spec.originToken);
        IL2AssetRouter(_assetRouter).atomicBridgeBurn({
            _destChainId: _spec.destChainId,
            _assetId: assetId,
            _originalCaller: address(this),
            _burnData: burnData
        });

        uint256 value = AtomicInteropProof.commitValue(_flowId, specHash);
        (uint256 index, ) = IL2InteropCommitmentTree(_commitmentTree).insert(value, _lowNullifierIndex);

        emit FlowCommitted(_flowId, specHash, _spec.depositor, index);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function authorize(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) external {
        bytes32[] memory specHashes = _computeAndCheckFlowId(_flowId, _specs, _chainIds, _deadline);

        // 1. Establish that every spec of the flow was committed before the deadline. Specs originating
        //    on THIS chain are checked via local `Committed` state (no proof); specs from other chains
        //    require an inclusion proof, consumed in order.
        // solhint-disable-next-line func-named-parameters
        _verifyFlowCommitted(_flowId, _specs, specHashes, _deadline, _proofs);

        // 2. Mark this chain's destination legs Executable.
        _markExecutable(_flowId, _specs, specHashes);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function execute(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Executable) revert EscrowSpecNotExecutable(specHash, s);
        if (_spec.destChainId != block.chainid) {
            revert EscrowSpecNotForThisChain(_spec.originChainId, _spec.destChainId);
        }
        _state[_flowId][specHash] = SpecState.Executed;

        _executeDestination(_spec);

        emit FlowExecuted(_flowId, specHash);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function authorizeRefund(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingSpecIndex,
        ImtNonInclusionProof calldata _proof
    ) external {
        bytes32[] memory specHashes = _computeAndCheckFlowId(_flowId, _specs, _chainIds, _deadline);

        // 1. Prove a spec is absent past the deadline -> the flow can no longer finalize.
        AtomicInteropProof.verifyNonInclusion(
            _proof,
            _specs[_missingSpecIndex].originChainId,
            AtomicInteropProof.commitValue(_flowId, specHashes[_missingSpecIndex]),
            _deadline
        );

        // 2. Mark this chain's source legs Revertable.
        _markRevertable(_flowId, _specs, specHashes);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Revertable) revert EscrowSpecNotRevertable(specHash, s);
        _state[_flowId][specHash] = SpecState.Reverted;

        // The tokens were burned/locked at commit, so recover (re-mint / unlock) them to the depositor
        // via AR/NTV, reversing the `atomicBridgeBurn`. `_destChainId` matches the burn so the NTV
        // chain-balance accounting reverses correctly.
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory recoverData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _spec.depositor,
            _remoteReceiver: _spec.depositor,
            _originToken: _spec.originToken,
            _amount: _spec.amount,
            _erc20Metadata: _spec.erc20Data
        });
        IL2AssetRouter(_assetRouter).recoverAtomicBurn(_spec.destChainId, assetId, recoverData);

        emit FlowRefunded(_flowId, specHash, _spec.depositor);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function specState(bytes32 _flowId, bytes32 _specHash) external view returns (SpecState) {
        return _state[_flowId][_specHash];
    }

    /// @inheritdoc IAtomicFlowEscrow
    function commitmentTree() external view returns (address) {
        return _commitmentTree;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function assetRouter() external view returns (address) {
        return _assetRouter;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function nativeTokenVault() external view returns (address) {
        return _nativeTokenVault;
    }

    /// @dev Extracted settle loop for `authorize` (non-via-IR stack relief). Only destination legs
    /// advance; source legs stay terminal at `Committed`.
    function _markExecutable(bytes32 _flowId, SendSpec[] calldata _specs, bytes32[] memory _specHashes) internal {
        uint256 n = _specs.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_specs[i].destChainId != block.chainid) continue;
            bytes32 specHash = _specHashes[i];
            SpecState s = _state[_flowId][specHash];
            // Destination legs are never committed locally, so the only valid prior state is Unset.
            if (s != SpecState.Unset) revert EscrowInvalidAuthorizeFromState(specHash, s);
            _state[_flowId][specHash] = SpecState.Executable;
            emit FlowAuthorized(_flowId, specHash);
        }
    }

    /// @dev Extracted settle loop for `authorizeRefund` (non-via-IR stack relief).
    function _markRevertable(bytes32 _flowId, SendSpec[] calldata _specs, bytes32[] memory _specHashes) internal {
        uint256 n = _specs.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_specs[i].originChainId != block.chainid) continue;
            bytes32 specHash = _specHashes[i];
            SpecState s = _state[_flowId][specHash];
            // Only Committed source legs can be refunded — destinations never burned anything.
            if (s != SpecState.Committed) revert EscrowInvalidRefundAuthorizeFromState(specHash, s);
            _state[_flowId][specHash] = SpecState.Revertable;
            emit FlowRefundAuthorized(_flowId, specHash);
        }
    }

    /// @dev Destination-side mint through AR/NTV (mirrors L2FlowEscrow._executeDestination).
    function _executeDestination(SendSpec calldata _spec) internal {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _spec.depositor,
            _remoteReceiver: _spec.recipient,
            _originToken: _spec.originToken,
            _amount: _spec.amount,
            _erc20Metadata: _spec.erc20Data
        });
        IAssetRouterFinalizeDeposit(_assetRouter).finalizeDeposit(_spec.originChainId, assetId, transferData);
    }

    /// @dev Recomputes `flowId` and asserts it matches, enforcing strictly-ascending `specHashes` and
    /// `_chainIds`. Returns the per-spec hashes in the provided (sorted) order.
    function _computeAndCheckFlowId(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        uint256[] calldata _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32[] memory specHashes) {
        uint256 n = _specs.length;
        specHashes = new bytes32[](n);
        bytes32 prev = bytes32(0);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 specHash = keccak256(abi.encode(_specs[i]));
            if (i != 0 && specHash <= prev) revert EscrowSpecsNotSorted();
            prev = specHash;
            specHashes[i] = specHash;
        }
        uint256 m = _chainIds.length;
        for (uint256 i = 1; i < m; ++i) {
            if (_chainIds[i] <= _chainIds[i - 1]) revert EscrowChainsNotSorted();
        }
        bytes32 computed = keccak256(abi.encode(specHashes, _chainIds, _deadline));
        if (computed != _flowId) revert EscrowFlowIdMismatch(_flowId, computed);
    }

    /// @dev Establishes that every spec of the flow was committed before the deadline:
    ///   - a spec whose origin is THIS chain was committed here, so its local state must be `Committed`
    ///     (no inclusion proof needed — it happened here);
    ///   - a spec from another chain requires an inclusion proof, consumed from `_proofs` in order.
    /// Reverts if any required proof is missing or if extra proofs are supplied.
    function _verifyFlowCommitted(
        bytes32 _flowId,
        SendSpec[] calldata _specs,
        bytes32[] memory _specHashes,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) internal view {
        uint256 n = _specs.length;
        uint256 p = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (_specs[i].originChainId == block.chainid) {
                SpecState s = _state[_flowId][_specHashes[i]];
                if (s != SpecState.Committed) revert EscrowSpecNotCommittedLocally(_specHashes[i], s);
                continue;
            }
            if (p >= _proofs.length) revert EscrowMissingProof(_specHashes[i]);
            uint256 value = AtomicInteropProof.commitValue(_flowId, _specHashes[i]);
            AtomicInteropProof.verifyInclusion(_proofs[p], _specs[i].originChainId, value, _deadline);
            ++p;
        }
        if (p != _proofs.length) revert EscrowProofCountMismatch(p, _proofs.length);
    }

    /// @dev Validation applied at `commitSend`: a source-side spec describing a real outbound transfer
    /// that originates on this chain.
    function _validateSourceSpec(SendSpec calldata _spec) internal view {
        if (_spec.destChainId == 0) revert EscrowSendSpecMissingDest();
        if (_spec.destChainId == block.chainid) revert EscrowSelfDestination(_spec.destChainId);
        if (_spec.originChainId != block.chainid) revert EscrowSendSpecZeroOriginChain();
        if (_spec.amount == 0) revert EscrowSendSpecZeroAmount();
        if (_spec.originToken == address(0)) revert EscrowSendSpecZeroToken();
        if (_spec.recipient == address(0)) revert EscrowSendSpecZeroRecipient();
    }
}
