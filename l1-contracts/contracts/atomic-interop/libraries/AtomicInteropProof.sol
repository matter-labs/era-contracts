// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTreeLib} from "../../common/libraries/IndexedMerkleTree.sol";
import {ImtInclusionProof, ImtNonInclusionProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {L2Message} from "../../common/Messaging.sol";
import {L2_MESSAGE_VERIFICATION} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {L2_INTEROP_COMMITMENT_TREE_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {
    ProofChainMismatch,
    ProofRootMessageInclusionFailed,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofInclusionFailed,
    ProofNonInclusionFailed
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Cross-chain authentication for the L1-free atomic interop flow.
///
/// A flow leg's commit value lives in its origin chain's {L2InteropCommitmentTree} (an Indexed
/// Merkle Tree). On every insert that tree publishes `abi.encode(root, block.timestamp)` to L1 via
/// the L2->L1 messenger. The verifying chain authenticates that single message against the interop
/// root it imported for `(sourceChainId, batchNumber)` — which it only holds once the source batch
/// has settled, so the bundled timestamp is covered by the batch validity proof and cannot be
/// forged. Membership (inclusion) and non-membership (low-nullifier) against the authenticated root
/// are delegated to {IndexedMerkleTreeLib}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s IMT as of an
    /// authenticated root whose bundled timestamp is `<= _deadline`.
    function verifyInclusion(
        ImtInclusionProof calldata _proof,
        uint256 _expectedChainId,
        uint256 _commitValue,
        uint64 _deadline
    ) internal view {
        if (_proof.sourceChainId != _expectedChainId) {
            revert ProofChainMismatch(_expectedChainId, _proof.sourceChainId);
        }
        if (_proof.rootTimestamp > _deadline) {
            revert ProofDeadlineExceeded(_proof.rootTimestamp, _deadline);
        }
        // solhint-disable-next-line func-named-parameters
        _authenticateRoot(
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.rootTimestamp,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        bool included = IndexedMerkleTreeLib.verifyInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _leaf: _proof.leaf,
            _leafIndex: _proof.imtLeafIndex,
            _proof: _proof.imtProof
        });
        if (!included) revert ProofInclusionFailed(_proof.chainImtRoot, _commitValue);
    }

    /// @notice Verifies `_commitValue` is absent from `_proof.sourceChainId`'s IMT as of an
    /// authenticated root whose bundled timestamp is `> _deadline` — so the leg can no longer be
    /// committed in time and the flow cannot finalize.
    function verifyNonInclusion(
        ImtNonInclusionProof calldata _proof,
        uint256 _expectedChainId,
        uint256 _commitValue,
        uint64 _deadline
    ) internal view {
        if (_proof.sourceChainId != _expectedChainId) {
            revert ProofChainMismatch(_expectedChainId, _proof.sourceChainId);
        }
        if (_proof.rootTimestamp <= _deadline) {
            revert ProofDeadlineNotExceeded(_proof.rootTimestamp, _deadline);
        }
        // solhint-disable-next-line func-named-parameters
        _authenticateRoot(
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.rootTimestamp,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        bool absent = IndexedMerkleTreeLib.verifyNonInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _lowLeaf: _proof.lowLeaf,
            _lowLeafIndex: _proof.lowLeafIndex,
            _lowLeafProof: _proof.imtProof
        });
        if (!absent) revert ProofNonInclusionFailed(_proof.chainImtRoot, _commitValue);
    }

    /// @dev Reconstructs and authenticates the commitment tree's `(root, timestamp)` L2->L1 message
    /// against the interop root imported for `(_sourceChainId, _batchNumber)`. Pinning the sender to
    /// {L2_INTEROP_COMMITMENT_TREE_ADDR} (identical on every chain) binds the root to the real tree;
    /// the interop-root channel binds it to `_sourceChainId`. The `abi.encode` here must match what
    /// {L2InteropCommitmentTree} publishes.
    function _authenticateRoot(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        bytes32 _chainImtRoot,
        uint256 _rootTimestamp,
        uint16 _messageTxNumberInBatch,
        uint256 _messageIndex,
        bytes32[] calldata _messageProof
    ) private view {
        L2Message memory message = L2Message({
            txNumberInBatch: _messageTxNumberInBatch,
            sender: L2_INTEROP_COMMITMENT_TREE_ADDR,
            data: abi.encode(_chainImtRoot, _rootTimestamp)
        });
        bool ok = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _sourceChainId,
            _blockOrBatchNumber: _batchNumber,
            _index: _messageIndex,
            _message: message,
            _proof: _messageProof
        });
        if (!ok) revert ProofRootMessageInclusionFailed(_sourceChainId, _batchNumber);
    }
}
