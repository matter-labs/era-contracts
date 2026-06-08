// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAtomicFlowEscrow} from "./IAtomicFlowEscrow.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IL2GlobalInteropRootImporter} from "./IL2GlobalInteropRootImporter.sol";
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
    EscrowSpecsNotSorted,
    ImporterBlockNotImported
} from "./AtomicInteropErrors.sol";

/// @dev `finalizeDeposit` is declared on `AssetRouterBase` but not on its interface. Tiny local
/// interface so the escrow can call it without pulling in the abstract contract (mirrors L2FlowEscrow).
interface IAssetRouterFinalizeDeposit {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowEscrow}. Mirrors `L2FlowEscrow`'s asset routing (burn on source / mint on
/// destination through the L2 asset router + native token vault), but gates `authorize` /
/// `authorizeRefund` on IMT proofs against an imported global interop-IMT root rather than an aliased
/// L1 linker call. The settlement asset mechanics are identical to the L1-coordinated escrow, so
/// cross-chain mints work the same way.
contract AtomicFlowEscrow is IAtomicFlowEscrow {
    using SafeERC20 for IERC20;

    /// @dev The append-only indexed interop IMT for this chain. Also the "initialized" flag.
    address internal _commitmentTree;
    /// @dev The global-root importer this escrow verifies proofs against.
    address internal _importer;
    /// @dev L2 asset router this escrow drives for burns/mints.
    address internal _assetRouter;
    /// @dev L2 native token vault used for source-side allowances.
    address internal _nativeTokenVault;

    /// @dev (flowId, specHash) => state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 specHash => SpecState)) internal _state;

    /// @notice One-shot initializer.
    /// @param _tree The {L2InteropCommitmentTree} this escrow inserts commit values into.
    /// @param _rootImporter The {L2GlobalInteropRootImporter} holding imported global roots.
    /// @param _ar The L2 asset router this escrow drives for burns/mints.
    /// @param _ntv The L2 native token vault `_ar` routes through.
    function initialize(address _tree, address _rootImporter, address _ar, address _ntv) external {
        if (_commitmentTree != address(0)) revert EscrowAlreadyInitialized();
        _commitmentTree = _tree;
        _importer = _rootImporter;
        _assetRouter = _ar;
        _nativeTokenVault = _ntv;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function commitSend(bytes32 _flowId, SendSpec calldata _spec, uint256 _lowNullifierIndex) external {
        _validateSourceSpec(_spec);
        if (msg.sender != _spec.depositor) revert EscrowDepositorMismatch(msg.sender, _spec.depositor);

        bytes32 specHash = keccak256(abi.encode(_spec));
        if (_state[_flowId][specHash] != SpecState.Unset) revert EscrowSpecAlreadyCommitted(specHash);
        _state[_flowId][specHash] = SpecState.Committed;

        IERC20(_spec.originToken).safeTransferFrom(_spec.depositor, address(this), _spec.amount);

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

        // 1. Establish that every spec of the flow was committed before the deadline. Specs that
        //    originate on THIS chain were committed here (we check local state — no proof needed);
        //    specs from other chains require an inclusion proof, consumed in order. A proof may thus
        //    be omitted for any local-origin spec.
        // solhint-disable-next-line func-named-parameters
        _verifyFlowCommitted(_flowId, _specs, specHashes, _deadline, _proofs);

        // 2. Mark the specs relevant to this chain Executable.
        _markExecutable(_flowId, _specs, specHashes);
    }

    /// @dev Extracted settle loop for `authorize` (non-via-IR stack relief).
    function _markExecutable(bytes32 _flowId, SendSpec[] calldata _specs, bytes32[] memory _specHashes) internal {
        uint256 n = _specs.length;
        for (uint256 i = 0; i < n; ++i) {
            SendSpec calldata spec = _specs[i];
            if (spec.originChainId != block.chainid && spec.destChainId != block.chainid) continue;
            bytes32 specHash = _specHashes[i];
            SpecState s = _state[_flowId][specHash];
            // Valid prior states: Unset (destination) or Committed (source).
            if (s != SpecState.Unset && s != SpecState.Committed) {
                revert EscrowInvalidAuthorizeFromState(specHash, s);
            }
            _state[_flowId][specHash] = SpecState.Executable;
            emit FlowAuthorized(_flowId, specHash);
        }
    }

    /// @inheritdoc IAtomicFlowEscrow
    function execute(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Executable) revert EscrowSpecNotExecutable(specHash, s);
        _state[_flowId][specHash] = SpecState.Executed;

        bool isSource;
        if (_spec.originChainId == block.chainid) {
            _executeSource(_spec);
            isSource = true;
        } else if (_spec.destChainId == block.chainid) {
            _executeDestination(_spec);
            isSource = false;
        } else {
            revert EscrowSpecNotForThisChain(_spec.originChainId, _spec.destChainId);
        }

        emit FlowExecuted(_flowId, specHash, isSource);
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

        // 1. Prove a spec is provably absent across the deadline boundary -> flow cannot finalize.
        _verifyNonInclusion(
            _proof,
            _specs[_missingSpecIndex].originChainId,
            AtomicInteropProof.commitValue(_flowId, specHashes[_missingSpecIndex]),
            _deadline
        );

        // 2. Mark this chain's source specs Revertable.
        _markRevertable(_flowId, _specs, specHashes);
    }

    /// @dev Extracted settle loop for `authorizeRefund` (non-via-IR stack relief).
    function _markRevertable(bytes32 _flowId, SendSpec[] calldata _specs, bytes32[] memory _specHashes) internal {
        uint256 n = _specs.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_specs[i].originChainId != block.chainid) continue;
            bytes32 specHash = _specHashes[i];
            SpecState s = _state[_flowId][specHash];
            // Only Committed entries can be refunded — destinations have no lock to return.
            if (s != SpecState.Committed) revert EscrowInvalidRefundAuthorizeFromState(specHash, s);
            _state[_flowId][specHash] = SpecState.Revertable;
            emit FlowRefundAuthorized(_flowId, specHash);
        }
    }

    /// @inheritdoc IAtomicFlowEscrow
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Revertable) revert EscrowSpecNotRevertable(specHash, s);
        _state[_flowId][specHash] = SpecState.Reverted;

        IERC20(_spec.originToken).safeTransfer(_spec.depositor, _spec.amount);

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
    function importer() external view returns (address) {
        return _importer;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function assetRouter() external view returns (address) {
        return _assetRouter;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function nativeTokenVault() external view returns (address) {
        return _nativeTokenVault;
    }

    /// @dev Source-side burn through AR/NTV (mirrors L2FlowEscrow._executeSource).
    function _executeSource(SendSpec calldata _spec) internal {
        IERC20(_spec.originToken).safeIncreaseAllowance(_nativeTokenVault, _spec.amount);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory burnData = DataEncoding.encodeBridgeBurnData(_spec.amount, _spec.recipient, _spec.originToken);
        bytes memory depositData = DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, burnData);
        IL2AssetRouter(_assetRouter).initiateIndirectCall({
            _chainId: _spec.destChainId,
            _originalCaller: address(this),
            _value: 0,
            _data: depositData
        });
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
    ///   - a spec whose origin is THIS chain was committed here, so its local state must be
    ///     `Committed` (no inclusion proof needed — it happened here);
    ///   - a spec from another chain requires an inclusion proof, consumed from `_proofs` in order.
    /// Reverts if any required proof is missing or if extra proofs are supplied.
    /// Extracted from `authorize` to keep that function's stack within the non-via-IR limit.
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
            (bytes32 importedRoot, uint256 importedTs) = _resolveImported(_proofs[p].l1BlockNumber);
            // solhint-disable-next-line func-named-parameters
            AtomicInteropProof.verifyInclusion(
                _proofs[p],
                _specs[i].originChainId,
                value,
                importedRoot,
                importedTs,
                _deadline
            );
            ++p;
        }
        if (p != _proofs.length) revert EscrowProofCountMismatch(p, _proofs.length);
    }

    /// @dev Resolves the before/after imported roots and runs the non-inclusion check. Extracted from
    /// `authorizeRefund` to keep that function's stack within the non-via-IR limit.
    function _verifyNonInclusion(
        ImtNonInclusionProof calldata _proof,
        uint256 _chainId,
        uint256 _commitValue,
        uint64 _deadline
    ) internal view {
        (bytes32 rootBefore, uint256 tsBefore) = _resolveImported(_proof.l1BlockNumberBeforeDeadline);
        (bytes32 rootAfter, uint256 tsAfter) = _resolveImported(_proof.l1BlockNumberAfterDeadline);
        // solhint-disable-next-line func-named-parameters
        AtomicInteropProof.verifyNonInclusion(
            _proof,
            _chainId,
            _commitValue,
            rootBefore,
            tsBefore,
            rootAfter,
            tsAfter,
            _deadline
        );
    }

    /// @dev Fetches the imported global root and timestamp for an L1 block number, reverting if none.
    function _resolveImported(uint256 _l1BlockNumber) internal view returns (bytes32 root, uint256 timestamp) {
        IL2GlobalInteropRootImporter imp = IL2GlobalInteropRootImporter(_importer);
        root = imp.globalRootAt(_l1BlockNumber);
        if (root == bytes32(0)) revert ImporterBlockNotImported(_l1BlockNumber);
        timestamp = imp.timestampAt(_l1BlockNumber);
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
