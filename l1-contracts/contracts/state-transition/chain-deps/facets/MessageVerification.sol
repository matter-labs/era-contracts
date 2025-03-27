// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2Message, L2Log} from "../../../common/Messaging.sol";
import {IMessageVerification} from "../../chain-interfaces/IMessageVerification.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "../../../common/Config.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {HashedLogIsDefault} from "../../../common/L1ContractErrors.sol";

abstract contract MessageVerification is IMessageVerification {
    /// @inheritdoc IMessageVerification
    function proveL2MessageInclusionShared(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return _proveL2LogInclusion(_chainId, _batchNumber, _index, _l2MessageToLog(_message), _proof);
    }

    /// @inheritdoc IMessageVerification
    function proveL2LeafInclusionShared(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        return _proveL2LeafInclusion(_chainId, _batchNumber, _leafProofMask, _leaf, _proof);
    }

    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view virtual returns (bool);

    /// @dev Prove that a specific L2 log was sent in a specific L2 batch number
    function _proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        bytes32 hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        if (hashedLog == L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH) {
            revert HashedLogIsDefault();
        }

        // It is ok to not check length of `_proof` array, as length
        // of leaf preimage (which is `L2_TO_L1_LOG_SERIALIZE_SIZE`) is not
        // equal to the length of other nodes preimages (which are `2 * 32`)

        // We can use `index` as a mask, since the `localMessageRoot` is on the left part of the tree.

        return _proveL2LeafInclusion(_chainId, _batchNumber, _index, hashedLog, _proof);
    }

    /// @dev Convert arbitrary-length message to the raw L2 log
    function _l2MessageToLog(L2Message calldata _message) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _message.txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(_message.sender))),
                value: keccak256(_message.data)
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL2LogInclusionShared(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return _proveL2LogInclusion(_chainId, _batchNumber, _index, _log, _proof);
    }
}
