// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2Log, L2Message, TxStatus} from "./Messaging.sol";
import {FinalizeL1DepositParams, IMessageVerification} from "./interfaces/IMessageVerification.sol";
import {MessageHashing} from "./libraries/MessageHashing.sol";

/// @title The interface of the ZKsync MessageVerification contract that can be used to prove L2 message inclusion.
/// @dev This contract is abstract and is inherited by the Mailbox and L2MessageVerification contracts.
/// @dev All calls go through via the _proveL2LeafInclusion function, which is different on L1 and L2.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
abstract contract MessageVerification is IMessageVerification {
    /// @inheritdoc IMessageVerification
    function proveL2MessageInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public view virtual returns (bool) {
        return
            _proveL2LogInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _index: _index,
                _log: MessageHashing._l2MessageToLog(_message),
                _proof: _proof
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL2LeafInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) public view virtual override returns (bool) {
        return
            _proveL2LeafInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    function proveL2LeafInclusionSharedRecursive(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _depth
    ) public view virtual returns (bool) {
        return
            _proveL2LeafInclusionRecursive({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof,
                _depth: _depth
            });
    }

    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view virtual returns (bool) {
        return
            _proveL2LeafInclusionRecursive({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof,
                _depth: 0
            });
    }

    function _proveL2LeafInclusionRecursive(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view virtual returns (bool);

    /// @dev Prove that a specific L2 log was sent in a specific L2 batch number
    function _proveL2LogInclusion(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        bytes32 hashedLog = MessageHashing.getLeafHashFromLog(_log);

        // It is ok to not check length of `_proof` array, as length
        // of leaf preimage (which is `L2_TO_L1_LOG_SERIALIZE_SIZE`) is not
        // equal to the length of other nodes preimages (which are `2 * 32`)

        // We can use `index` as a mask, since the `LocalLogsRoot` is on the left part of the tree.

        return
            _proveL2LeafInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _index,
                _leaf: hashedLog,
                _proof: _proof
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL2LogInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) public view virtual returns (bool) {
        return
            _proveL2LogInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _index: _index,
                _log: _log,
                _proof: _proof
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL1ToL2TransactionStatusShared(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) public view returns (bool) {
        L2Log memory l2Log = MessageHashing.getL2LogFromL1ToL2Transaction(_l2TxNumberInBatch, _l2TxHash, _status);
        return
            _proveL2LogInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _l2BatchNumber,
                _index: _l2MessageIndex,
                _log: l2Log,
                _proof: _merkleProof
            });
    }

    function proveL1DepositParamsInclusion(
        FinalizeL1DepositParams calldata _finalizeWithdrawalParams
    ) public view returns (bool success) {
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
            sender: _finalizeWithdrawalParams.l2Sender,
            data: _finalizeWithdrawalParams.message
        });

        success = this.proveL2MessageInclusionShared({
            _chainId: _finalizeWithdrawalParams.chainId,
            _blockOrBatchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _index: _finalizeWithdrawalParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _finalizeWithdrawalParams.merkleProof
        });
    }
}
