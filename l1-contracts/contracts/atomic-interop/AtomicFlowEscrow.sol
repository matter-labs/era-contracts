// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAtomicFlowEscrow} from "./IAtomicFlowEscrow.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {IL2GlobalInteropRootImporter} from "./IL2GlobalInteropRootImporter.sol";
import {AtomicInteropProof} from "./libraries/AtomicInteropProof.sol";
import {FlowLeg, PartState, ImtInclusionProof, ImtNonInclusionProof} from "./IAtomicInterop.sol";
import {
    EscrowAlreadyInitialized,
    EscrowChainsNotSorted,
    EscrowFlowIdMismatch,
    EscrowLegNotOnThisChain,
    EscrowLegZeroAmount,
    EscrowLegZeroPayee,
    EscrowLegZeroPayer,
    EscrowLegZeroToken,
    EscrowPartNotCommitted,
    EscrowPartNotUnset,
    EscrowPayerMismatch,
    EscrowProofCountMismatch,
    EscrowSpecsNotSorted,
    ImporterBlockNotImported
} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IAtomicFlowEscrow}. Self-custodial demo escrow: each leg locks tokens on its own
/// chain at commit time and releases them (to the payee on finalize, back to the payer on refund)
/// once the flow's global outcome is *proven* — there is no L1 linker and no cross-chain message.
///
/// @dev The asset mechanics (lock/release of a held ERC20) are intentionally a thin demo stand-in
/// for the bridge/NTV routing used by the L1-coordinated `dummy-interop` escrow; the focus here is
/// the IMT-based, L1-free coordination. Swapping in AR/NTV settlement would not change the proof
/// logic.
contract AtomicFlowEscrow is IAtomicFlowEscrow {
    using SafeERC20 for IERC20;

    /// @dev The append-only interop commitment tree for this chain. Also the "initialized" flag.
    address internal _commitmentTree;
    /// @dev The global-root importer this escrow verifies proofs against.
    address internal _importer;

    /// @dev (flowId, specHash) => leg state on this chain.
    mapping(bytes32 flowId => mapping(bytes32 specHash => PartState)) internal _state;

    /// @notice One-shot initializer.
    /// @param _tree The {L2InteropCommitmentTree} this escrow appends commit leaves to.
    /// @param _rootImporter The {L2GlobalInteropRootImporter} holding imported global roots.
    function initialize(address _tree, address _rootImporter) external {
        if (_commitmentTree != address(0)) revert EscrowAlreadyInitialized();
        _commitmentTree = _tree;
        _importer = _rootImporter;
    }

    /// @inheritdoc IAtomicFlowEscrow
    function commitPart(bytes32 _flowId, FlowLeg calldata _leg, uint256 _lowNullifierIndex) external {
        if (_leg.chainId != block.chainid) revert EscrowLegNotOnThisChain(_leg.chainId);
        if (_leg.amount == 0) revert EscrowLegZeroAmount();
        if (_leg.token == address(0)) revert EscrowLegZeroToken();
        if (_leg.payer == address(0)) revert EscrowLegZeroPayer();
        if (_leg.payee == address(0)) revert EscrowLegZeroPayee();
        if (msg.sender != _leg.payer) revert EscrowPayerMismatch(msg.sender, _leg.payer);

        bytes32 specHash = keccak256(abi.encode(_leg));
        if (_state[_flowId][specHash] != PartState.Unset)
            revert EscrowPartNotUnset(specHash, _state[_flowId][specHash]);
        _state[_flowId][specHash] = PartState.Committed;

        IERC20(_leg.token).safeTransferFrom(_leg.payer, address(this), _leg.amount);

        uint256 value = AtomicInteropProof.commitValue(_flowId, specHash);
        (uint256 index, ) = IL2InteropCommitmentTree(_commitmentTree).insert(value, _lowNullifierIndex);

        emit PartCommitted(_flowId, specHash, _leg.payer, index);
    }

    /// @inheritdoc IAtomicFlowEscrow
    function finalize(
        bytes32 _flowId,
        FlowLeg[] calldata _legs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        ImtInclusionProof[] calldata _proofs
    ) external {
        bytes32[] memory specHashes = _computeAndCheckFlowId(_flowId, _legs, _chainIds, _deadline);
        if (_proofs.length != _legs.length) revert EscrowProofCountMismatch(_legs.length, _proofs.length);

        // 1. Prove every leg of the flow was committed before the deadline.
        uint256 n = _legs.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 value = AtomicInteropProof.commitValue(_flowId, specHashes[i]);
            (bytes32 importedRoot, uint256 importedTs) = _resolveImported(_proofs[i].l1BlockNumber);
            // solhint-disable-next-line func-named-parameters
            AtomicInteropProof.verifyInclusion(
                _proofs[i],
                _legs[i].chainId,
                value,
                importedRoot,
                importedTs,
                _deadline
            );
        }

        // 2. Release this chain's committed leg(s) to their payees.
        for (uint256 i = 0; i < n; ++i) {
            FlowLeg calldata leg = _legs[i];
            if (leg.chainId != block.chainid) continue;
            bytes32 specHash = specHashes[i];
            if (_state[_flowId][specHash] != PartState.Committed) {
                revert EscrowPartNotCommitted(specHash, _state[_flowId][specHash]);
            }
            _state[_flowId][specHash] = PartState.Finalized;
            IERC20(leg.token).safeTransfer(leg.payee, leg.amount);
            emit PartFinalized(_flowId, specHash, leg.payee, leg.amount);
        }
    }

    /// @inheritdoc IAtomicFlowEscrow
    function refund(
        bytes32 _flowId,
        FlowLeg[] calldata _legs,
        uint256[] calldata _chainIds,
        uint64 _deadline,
        uint256 _missingLegIndex,
        ImtNonInclusionProof calldata _proof
    ) external {
        bytes32[] memory specHashes = _computeAndCheckFlowId(_flowId, _legs, _chainIds, _deadline);

        // 1. Prove a leg is provably absent across the deadline boundary -> flow cannot finalize.
        _verifyNonInclusion(
            _proof,
            _legs[_missingLegIndex].chainId,
            AtomicInteropProof.commitValue(_flowId, specHashes[_missingLegIndex]),
            _deadline
        );

        // 2. Return this chain's committed leg(s) to their payers.
        uint256 n = _legs.length;
        for (uint256 i = 0; i < n; ++i) {
            FlowLeg calldata leg = _legs[i];
            if (leg.chainId != block.chainid) continue;
            bytes32 specHash = specHashes[i];
            if (_state[_flowId][specHash] != PartState.Committed) {
                revert EscrowPartNotCommitted(specHash, _state[_flowId][specHash]);
            }
            _state[_flowId][specHash] = PartState.Refunded;
            IERC20(leg.token).safeTransfer(leg.payer, leg.amount);
            emit PartRefunded(_flowId, specHash, leg.payer, leg.amount);
        }
    }

    /// @inheritdoc IAtomicFlowEscrow
    function partState(bytes32 _flowId, bytes32 _specHash) external view returns (PartState) {
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

    /// @dev Recomputes `flowId` from the legs/chains/deadline exactly as the off-chain coordinator
    /// does and asserts it matches `_flowId`. Enforces strictly-ascending `specHashes` and
    /// `_chainIds` (sorted + deduplicated), which canonicalizes the preimage.
    /// @return specHashes The per-leg spec hashes in the provided (sorted) order.
    function _computeAndCheckFlowId(
        bytes32 _flowId,
        FlowLeg[] calldata _legs,
        uint256[] calldata _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32[] memory specHashes) {
        uint256 n = _legs.length;
        specHashes = new bytes32[](n);
        bytes32 prev = bytes32(0);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 specHash = keccak256(abi.encode(_legs[i]));
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

    /// @dev Resolves the before/after imported roots and runs the non-inclusion check. Extracted
    /// from `refund` to keep that function's stack within the non-via-IR limit.
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

    /// @dev Fetches the imported global root and timestamp for an L1 block number, reverting if no
    /// root was imported for it.
    function _resolveImported(uint256 _l1BlockNumber) internal view returns (bytes32 root, uint256 timestamp) {
        IL2GlobalInteropRootImporter imp = IL2GlobalInteropRootImporter(_importer);
        root = imp.globalRootAt(_l1BlockNumber);
        if (root == bytes32(0)) revert ImporterBlockNotImported(_l1BlockNumber);
        timestamp = imp.timestampAt(_l1BlockNumber);
    }
}
