// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2Log, L2Message} from "../../../common/Messaging.sol";
import {IMessageVerification} from "../../chain-interfaces/IMessageVerification.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "../../../common/Config.sol";
import {HashedLogIsDefault} from "../../../common/L1ContractErrors.sol";
import {MessageHashing} from "../../../common/libraries/MessageHashing.sol";

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
    ) public view returns (bool) {
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
    ) external view override returns (bool) {
        return
            _proveL2LeafInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
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
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        if (hashedLog == L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH) {
            revert HashedLogIsDefault();
        }

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
    ) external view returns (bool) {
        return
            _proveL2LogInclusion({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _index: _index,
                _log: _log,
                _proof: _proof
            });
    }
}
