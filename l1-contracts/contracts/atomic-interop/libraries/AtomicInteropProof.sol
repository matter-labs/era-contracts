// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IndexedMerkleTree} from "../../common/libraries/IndexedMerkleTree.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {IMessageVerification} from "../../common/interfaces/IMessageVerification.sol";
import {L2Message, ProofData} from "../../common/Messaging.sol";
import {ImtInclusionProof, ImtTimeoutProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {
    AtomicProofChainMismatch,
    AtomicRootMessageInclusionFailed,
    AtomicMissingSettlementLayerAnchor,
    AtomicDeadlineExceeded,
    AtomicDeadlineNotExceeded,
    AtomicInclusionFailed,
    AtomicNonInclusionFailed
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Verifies whether a flow leg's commit value was committed — or, for a timeout, was not committed —
/// in its source chain's commitment tree (an Indexed Merkle Tree) by a deadline, reusing the existing
/// message-root verification pipeline rather than adding new settlement-layer trees.
/// @dev The deadline is a settlement-layer block number that the prover never supplies directly: it is
/// re-derived from the same proof that authenticates the commitment-tree root (see {_authenticateRoot}), so
/// it cannot be spoofed. Inclusion requires that block `<= deadline` and timeout requires `> deadline` which,
/// together with the append-only tree, makes a leg's finalize and refund paths mutually exclusive.
/// @dev Caller invariants: a flow's legs must all authenticate against the same settlement layer (block
/// numbers are not comparable across layers), so the verify functions return `slChainId` for the caller to
/// check; and the injected `_verifier` / `_commitmentTreeSender` must be the canonical message verifier and
/// commitment-tree address. Both are parameters so the library is usable on L1 and L2.
library AtomicInteropProof {
    /// @notice The value inserted into a source chain's commitment tree when a flow leg is committed.
    /// @param _flowId The flow identifier binding all legs.
    /// @param _specHash The hash of this leg's spec.
    /// @return The domain-tagged commit value.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` was committed in `_expectedSourceChainId`'s commitment tree as of a
    /// root authenticated at a settlement-layer block `<= _deadline`.
    /// @param _proof The inclusion proof.
    /// @param _verifier The message verifier used to authenticate the commitment-tree root message.
    /// @param _commitmentTreeSender The canonical commitment-tree address the root message is pinned to.
    /// @param _expectedSourceChainId The source chain the leg must have originated on.
    /// @param _commitValue The commit value (see {commitValue}) expected to be present.
    /// @param _deadline The flow deadline, a settlement-layer block number.
    /// @return slChainId The settlement layer the root was authenticated on (see the caller invariants above).
    function verifyInclusion(
        ImtInclusionProof calldata _proof,
        IMessageVerification _verifier,
        address _commitmentTreeSender,
        uint256 _expectedSourceChainId,
        uint256 _commitValue,
        uint256 _deadline
    ) internal view returns (uint256 slChainId) {
        if (_proof.sourceChainId != _expectedSourceChainId) {
            revert AtomicProofChainMismatch(_expectedSourceChainId, _proof.sourceChainId);
        }

        uint256 slBlock;
        // solhint-disable-next-line func-named-parameters
        (slBlock, slChainId) = _authenticateRoot(
            _verifier,
            _commitmentTreeSender,
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        if (slBlock > _deadline) {
            revert AtomicDeadlineExceeded(slBlock, _deadline);
        }

        bool included = IndexedMerkleTree.verifyInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _leaf: _proof.leaf,
            _leafIndex: _proof.imtLeafIndex,
            _proof: _proof.imtProof
        });
        if (!included) {
            revert AtomicInclusionFailed(_proof.chainImtRoot, _commitValue);
        }
    }

    /// @notice Verifies `_commitValue` was absent from `_expectedSourceChainId`'s commitment tree as of a
    /// root authenticated at a settlement-layer block `> _deadline` (the timeout / refund path).
    /// @param _proof The timeout (non-inclusion) proof.
    /// @param _verifier The message verifier used to authenticate the commitment-tree root message.
    /// @param _commitmentTreeSender The canonical commitment-tree address the root message is pinned to.
    /// @param _expectedSourceChainId The source chain the leg must have originated on.
    /// @param _commitValue The commit value (see {commitValue}) expected to be absent.
    /// @param _deadline The flow deadline, a settlement-layer block number.
    /// @return slChainId The settlement layer the root was authenticated on (see the caller invariants above).
    function verifyTimeout(
        ImtTimeoutProof calldata _proof,
        IMessageVerification _verifier,
        address _commitmentTreeSender,
        uint256 _expectedSourceChainId,
        uint256 _commitValue,
        uint256 _deadline
    ) internal view returns (uint256 slChainId) {
        if (_proof.sourceChainId != _expectedSourceChainId) {
            revert AtomicProofChainMismatch(_expectedSourceChainId, _proof.sourceChainId);
        }

        uint256 slBlock;
        // solhint-disable-next-line func-named-parameters
        (slBlock, slChainId) = _authenticateRoot(
            _verifier,
            _commitmentTreeSender,
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        if (slBlock <= _deadline) {
            revert AtomicDeadlineNotExceeded(slBlock, _deadline);
        }

        bool absent = IndexedMerkleTree.verifyNonInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _lowLeaf: _proof.lowLeaf,
            _lowLeafIndex: _proof.lowLeafIndex,
            _lowLeafProof: _proof.imtProof
        });
        if (!absent) {
            revert AtomicNonInclusionFailed(_proof.chainImtRoot, _commitValue);
        }
    }

    /// @notice Authenticates `_chainImtRoot` against an imported interop root and returns the settlement
    /// layer (block number and chain id) that authenticated it.
    /// @dev Reconstructs the commitment tree's canonical L2->L1 message (sender pinned to
    /// `_commitmentTreeSender`, data `abi.encode(_chainImtRoot)`), proves it via the existing
    /// {IMessageVerification.proveL2MessageInclusionShared}, then re-parses the SAME proof with
    /// {MessageHashing._getProofData} to read the settlement-layer block. Both parses consume identical
    /// inputs, so that block is provably the one whose imported interop root authenticated the root. A
    /// final-node proof carries no settlement-layer block and is rejected.
    /// @return slBlock The settlement-layer block number that authenticated the root.
    /// @return slChainId The settlement-layer chain id that authenticated the root.
    function _authenticateRoot(
        IMessageVerification _verifier,
        address _commitmentTreeSender,
        uint256 _sourceChainId,
        uint256 _batchNumber,
        bytes32 _chainImtRoot,
        uint16 _messageTxNumberInBatch,
        uint256 _messageIndex,
        bytes32[] calldata _messageProof
    ) private view returns (uint256 slBlock, uint256 slChainId) {
        L2Message memory message = L2Message({
            txNumberInBatch: _messageTxNumberInBatch,
            sender: _commitmentTreeSender,
            data: abi.encode(_chainImtRoot)
        });

        bool ok = _verifier.proveL2MessageInclusionShared({
            _chainId: _sourceChainId,
            _blockOrBatchNumber: _batchNumber,
            _index: _messageIndex,
            _message: message,
            _proof: _messageProof
        });
        if (!ok) {
            revert AtomicRootMessageInclusionFailed(_sourceChainId, _batchNumber);
        }

        // Re-parse the same proof to read the settlement-layer anchor (bound to the verified root).
        ProofData memory proofData = MessageHashing._getProofData({
            _chainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _messageIndex,
            _leaf: MessageHashing.getLeafHashFromMessage(message),
            _proof: _messageProof
        });
        if (proofData.finalProofNode) {
            revert AtomicMissingSettlementLayerAnchor(_sourceChainId, _batchNumber);
        }

        slBlock = proofData.settlementLayerBatchNumber;
        slChainId = proofData.settlementLayerChainId;
    }
}
