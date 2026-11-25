// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH} from "contracts/core/message-root/IMessageRoot.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";

/// @notice Builds the inclusion proofs of one-way bundles from the trees the messages are in. Proof layout:
/// {protocol-docs/interop.md#proof-of-a-local-message} and {protocol-docs/message-root.md#proof-paths}.
library OneWayBundleProofBuilder {
    /// @dev The siblings of leaf 0 (the logs root) in the chain batch root tree of a batch without a multichain
    /// root or interop commitments.
    uint256 internal constant CHAIN_BATCH_ROOT_SIBLINGS = 3;

    /// @notice The leaf of a message of `_sender` whose data hashes to `keccak256(_data)`.
    function messageLeaf(address _sender, bytes memory _data) internal pure returns (bytes32) {
        return MessageHashing.getLeafHashFromMessage(L2Message({txNumberInBatch: 0, sender: _sender, data: _data}));
    }

    /// @notice The chain batch root of a batch whose logs tree has the root `_logsRoot`.
    function chainBatchRoot(bytes32 _logsRoot) internal pure returns (bytes32) {
        return
            ChainBatchRootTree.compute(
                _logsRoot,
                bytes32(0),
                ChainBatchRootTree.EMPTY_IMT_ROOT,
                ChainBatchRootTree.EMPTY_IMT_ROOT
            );
    }

    /// @notice The proof of the only message of batch `_batchNumber` of the message root's own chain, down to the
    /// shared-tree root of the message root's current state.
    /// @param _messageRoot The message root of the chain that sent the message.
    /// @param _batchNumber The local batch that holds the message.
    /// @param _rootBlockNumber The block whose recorded root the proof ends at. The message root must not have
    /// changed since that block.
    function localMessageProof(
        L1MessageRoot _messageRoot,
        uint256 _batchNumber,
        uint256 _rootBlockNumber
    ) internal view returns (bytes32[] memory) {
        uint256 chainId = _messageRoot.L1_CHAIN_ID();
        uint256 batchCount = _messageRoot.currentChainBatchNumber(chainId);
        bytes32[] memory batchLeaves = new bytes32[](batchCount);
        for (uint256 i = 0; i < batchCount; ++i) {
            batchLeaves[i] = MessageHashing.batchLeafHash(
                _messageRoot.chainBatchRoots(chainId, i + 1),
                i + 1,
                _messageRoot.chainBatchRootTimestamp(chainId, i + 1)
            );
        }
        return
            twoHopProof({
                _logLeafSiblings: chainBatchRootSiblings(new bytes32[](0)),
                _batchTimestamp: _messageRoot.chainBatchRootTimestamp(chainId, _batchNumber),
                // The local batches start at 1 and nothing seeds a genesis batch, so batch k is leaf k - 1.
                _batchLeafIndex: _batchNumber - 1,
                _batchLeafSiblings: merklePath(batchLeaves, _batchNumber - 1, CHAIN_TREE_EMPTY_ENTRY_HASH),
                _rootBlockNumber: _rootBlockNumber,
                _rootChainId: chainId,
                _chainIndex: _messageRoot.chainIndex(chainId),
                _sharedTreeSiblings: _messageRoot.getMerklePathForChain(chainId)
            });
    }

    /// @notice A proof with two hops: the message in its batch and the batch in its chain's tree, then that chain's
    /// leaf in a shared tree whose root is the root of `_rootChainId` at `_rootBlockNumber`.
    function twoHopProof(
        bytes32[] memory _logLeafSiblings,
        uint256 _batchTimestamp,
        uint256 _batchLeafIndex,
        bytes32[] memory _batchLeafSiblings,
        uint256 _rootBlockNumber,
        uint256 _rootChainId,
        uint256 _chainIndex,
        bytes32[] memory _sharedTreeSiblings
    ) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](
            1 + _logLeafSiblings.length + 2 + _batchLeafSiblings.length + 2 + 1 + _sharedTreeSiblings.length
        );
        uint256 ptr;
        proof[ptr++] = _metadata(_logLeafSiblings.length, _batchLeafSiblings.length, false);
        for (uint256 i = 0; i < _logLeafSiblings.length; ++i) {
            proof[ptr++] = _logLeafSiblings[i];
        }
        proof[ptr++] = bytes32(_batchTimestamp);
        proof[ptr++] = bytes32(_batchLeafIndex);
        for (uint256 i = 0; i < _batchLeafSiblings.length; ++i) {
            proof[ptr++] = _batchLeafSiblings[i];
        }
        proof[ptr++] = bytes32((_rootBlockNumber << 128) | _chainIndex);
        proof[ptr++] = bytes32(_rootChainId);
        proof[ptr++] = _metadata(_sharedTreeSiblings.length, 0, true);
        for (uint256 i = 0; i < _sharedTreeSiblings.length; ++i) {
            proof[ptr++] = _sharedTreeSiblings[i];
        }
    }

    /// @notice A proof with one hop, which ends at the chain batch root of the batch.
    /// @param _logsTreeSiblings The siblings of the message in the batch's logs tree.
    function finalProof(bytes32[] memory _logsTreeSiblings) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory siblings = chainBatchRootSiblings(_logsTreeSiblings);
        proof = new bytes32[](1 + siblings.length);
        proof[0] = _metadata(siblings.length, 0, true);
        for (uint256 i = 0; i < siblings.length; ++i) {
            proof[i + 1] = siblings[i];
        }
    }

    /// @notice `_logsTreeSiblings`, then the siblings of the logs root in the chain batch root tree.
    function chainBatchRootSiblings(
        bytes32[] memory _logsTreeSiblings
    ) internal pure returns (bytes32[] memory siblings) {
        uint256 logsDepth = _logsTreeSiblings.length;
        siblings = new bytes32[](logsDepth + CHAIN_BATCH_ROOT_SIBLINGS);
        for (uint256 i = 0; i < logsDepth; ++i) {
            siblings[i] = _logsTreeSiblings[i];
        }
        siblings[logsDepth] = bytes32(0);
        siblings[logsDepth + 1] = Merkle.efficientHash(
            ChainBatchRootTree.EMPTY_IMT_ROOT,
            ChainBatchRootTree.EMPTY_IMT_ROOT
        );
        siblings[logsDepth + 2] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
    }

    /// @notice The siblings of leaf `_index` in the smallest tree that holds `_leaves`, padded with `_emptyLeaf`.
    function merklePath(
        bytes32[] memory _leaves,
        uint256 _index,
        bytes32 _emptyLeaf
    ) internal pure returns (bytes32[] memory) {
        uint256 depth;
        while ((1 << depth) < _leaves.length) {
            ++depth;
        }
        return merklePath(_leaves, _index, _emptyLeaf, depth);
    }

    /// @notice The siblings of leaf `_index` in a tree of `_depth` levels that holds `_leaves`, padded with
    /// `_emptyLeaf`.
    function merklePath(
        bytes32[] memory _leaves,
        uint256 _index,
        bytes32 _emptyLeaf,
        uint256 _depth
    ) internal pure returns (bytes32[] memory siblings) {
        siblings = new bytes32[](_depth);
        bytes32[] memory level = new bytes32[](1 << _depth);
        for (uint256 i = 0; i < level.length; ++i) {
            level[i] = i < _leaves.length ? _leaves[i] : _emptyLeaf;
        }
        uint256 index = _index;
        for (uint256 d = 0; d < _depth; ++d) {
            siblings[d] = level[index ^ 1];
            bytes32[] memory nextLevel = new bytes32[](level.length / 2);
            for (uint256 i = 0; i < nextLevel.length; ++i) {
                nextLevel[i] = Merkle.efficientHash(level[2 * i], level[2 * i + 1]);
            }
            level = nextLevel;
            index >>= 1;
        }
    }

    /// @notice The root of a tree of `_depth` levels that holds `_leaves`, padded with the default leaf of the L2
    /// logs tree.
    function logsRoot(bytes32[] memory _leaves, uint256 _depth) internal pure returns (bytes32) {
        bytes32[] memory siblings = merklePath(_leaves, 0, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, _depth);
        return Merkle.calculateRootMemory(siblings, 0, _leaves[0]);
    }

    function _metadata(
        uint256 _logLeafProofLen,
        uint256 _batchLeafProofLen,
        bool _finalProofNode
    ) private pure returns (bytes32) {
        return
            bytes32(
                abi.encodePacked(
                    uint8(SUPPORTED_PROOF_METADATA_VERSION),
                    uint8(_logLeafProofLen),
                    uint8(_batchLeafProofLen),
                    _finalProofNode ? uint8(1) : uint8(0),
                    bytes28(0)
                )
            );
    }
}
