// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKsyncOSBatchMirrorSharedTest} from "./_ZKsyncOSBatchMirror_Shared.t.sol";

import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "contracts/common/Config.sol";
import {BatchZeroNotAllowed} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice End to end: a batch of the followed chain that sent an L2->L1 message is mirrored, and the
/// message is proven on the host chain with the standard `MessageRoot.proveL2MessageInclusionShared`,
/// with the proof the followed chain's node returns for a chain settling on its settlement layer directly.
contract ZKsyncOSBatchMirrorMessageProofTest is ZKsyncOSBatchMirrorSharedTest {
    /// @dev Depth of the batch's L2->L1 logs tree in this test; the proof format does not fix it.
    uint256 internal constant LOGS_TREE_DEPTH = 3;
    uint256 internal constant MESSAGE_INDEX = 5;

    L2Message internal message;
    bytes32[] internal logsTreeLeaves;
    uint256 internal messageBatchNumber;

    function setUp() public virtual override {
        super.setUp();
        message = L2Message({txNumberInBatch: 2, sender: makeAddr("l2Sender"), data: "hello from the followed chain"});
        logsTreeLeaves = new bytes32[](1 << LOGS_TREE_DEPTH);
        for (uint256 i = 0; i < logsTreeLeaves.length; ++i) {
            logsTreeLeaves[i] = L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH;
        }
        logsTreeLeaves[1] = keccak256("another log");
        logsTreeLeaves[MESSAGE_INDEX] = MessageHashing.getLeafHashFromMessage(message);
    }

    function test_mirroredMessageIsProvenThroughTheMessageRoot() public {
        // Batch 6 holds no message; batch 7 holds it; both are mirrored in one range.
        bytes32[] memory roots = new bytes32[](2);
        roots[0] = _chainBatchRoot(keccak256("no messages"));
        roots[1] = _chainBatchRoot(_logsRoot());
        Range memory range = _sealWithRoots(roots, new bytes32[](2));
        messageBatchNumber = range.batches[1].batchNumber;
        bytes32[] memory proof = _messageProof();

        assertFalse(_prove(messageBatchNumber, MESSAGE_INDEX, message, proof), "proven before it was mirrored");
        _mirror(range);
        assertTrue(_prove(messageBatchNumber, MESSAGE_INDEX, message, proof));

        // `proveL1DepositParamsInclusion`-style callers reach the same check through the leaf entry point.
        assertTrue(
            messageRoot.proveL2LeafInclusionShared(
                FOLLOWED_CHAIN_ID,
                messageBatchNumber,
                MESSAGE_INDEX,
                MessageHashing.getLeafHashFromMessage(message),
                proof
            )
        );
    }

    function test_onlyTheMessageThatWasSentIsProven() public {
        _mirrorMessageBatch();
        bytes32[] memory proof = _messageProof();

        L2Message memory other = message;
        other.data = "goodbye";
        assertFalse(_prove(messageBatchNumber, MESSAGE_INDEX, other, proof), "other data");

        other = message;
        other.sender = makeAddr("someoneElse");
        assertFalse(_prove(messageBatchNumber, MESSAGE_INDEX, other, proof), "other sender");

        other = message;
        other.txNumberInBatch += 1;
        assertFalse(_prove(messageBatchNumber, MESSAGE_INDEX, other, proof), "other transaction");

        assertFalse(_prove(messageBatchNumber, MESSAGE_INDEX + 1, message, proof), "other position");
        assertFalse(_prove(messageBatchNumber - 1, MESSAGE_INDEX, message, proof), "other batch");
        assertFalse(
            messageRoot.proveL2MessageInclusionShared(
                FOLLOWED_CHAIN_ID + 1,
                messageBatchNumber,
                MESSAGE_INDEX,
                message,
                proof
            ),
            "other chain"
        );
    }

    function test_batchZeroCannotBeProven() public {
        _mirrorMessageBatch();
        bytes32[] memory proof = _messageProof();

        vm.expectRevert(BatchZeroNotAllowed.selector);
        messageRoot.proveL2MessageInclusionShared(FOLLOWED_CHAIN_ID, 0, MESSAGE_INDEX, message, proof);
    }

    /// @notice The chain root the MessageRoot aggregates for the followed chain is built from the mirrored
    /// batch roots, so the host chain's interop root commits to them as it does for a settling chain.
    function test_mirroredRootsEnterTheChainTree() public {
        bytes32 chainRootBefore = messageRoot.getChainRoot(FOLLOWED_CHAIN_ID);
        uint256 leafCountBefore = messageRoot.chainTreeLeafCount(FOLLOWED_CHAIN_ID);
        _mirrorMessageBatch();

        assertEq(messageRoot.chainTreeLeafCount(FOLLOWED_CHAIN_ID), leafCountBefore + 2);
        assertNotEq(messageRoot.getChainRoot(FOLLOWED_CHAIN_ID), chainRootBefore);
    }

    function _mirrorMessageBatch() internal {
        _mirror(_seal(1));
        bytes32[] memory roots = new bytes32[](1);
        roots[0] = _chainBatchRoot(_logsRoot());
        Range memory range = _sealWithRoots(roots, new bytes32[](1));
        messageBatchNumber = range.batches[0].batchNumber;
        _mirror(range);
    }

    function _prove(
        uint256 _batchNumber,
        uint256 _index,
        L2Message memory _message,
        bytes32[] memory _proof
    ) internal view returns (bool) {
        return messageRoot.proveL2MessageInclusionShared(FOLLOWED_CHAIN_ID, _batchNumber, _index, _message, _proof);
    }

    function _logsRoot() internal view returns (bytes32) {
        bytes32[] memory level = logsTreeLeaves;
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i = 0; i < next.length; ++i) {
                next[i] = keccak256(abi.encode(level[2 * i], level[2 * i + 1]));
            }
            level = next;
        }
        return level[0];
    }

    /// @dev The proof of the message in its batch, in the format the node returns: the metadata word, the
    /// path in the logs tree, then the path from the logs root (leaf 0) to the chain batch root.
    function _messageProof() internal view returns (bytes32[] memory proof) {
        uint256 logLeafProofLength = LOGS_TREE_DEPTH + ChainBatchRootTree.TREE_DEPTH;
        proof = new bytes32[](1 + logLeafProofLength);
        // Version 1, the log leaf proof length, no batch leaf proof, and the final proof node flag.
        proof[0] = bytes32((uint256(1) << 248) | (logLeafProofLength << 240) | (uint256(1) << 224));

        bytes32[] memory level = logsTreeLeaves;
        uint256 index = MESSAGE_INDEX;
        for (uint256 depth = 0; depth < LOGS_TREE_DEPTH; ++depth) {
            proof[1 + depth] = level[index ^ 1];
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i = 0; i < next.length; ++i) {
                next[i] = keccak256(abi.encode(level[2 * i], level[2 * i + 1]));
            }
            level = next;
            index /= 2;
        }
        // Leaf 0 of the chain batch root tree: siblings are the multichain root, the interop commitment
        // tree node and the reserved right subtree.
        proof[1 + LOGS_TREE_DEPTH] = bytes32(0);
        proof[2 + LOGS_TREE_DEPTH] = keccak256(
            bytes.concat(ChainBatchRootTree.EMPTY_IMT_ROOT, ChainBatchRootTree.EMPTY_IMT_ROOT)
        );
        proof[3 + LOGS_TREE_DEPTH] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
    }
}
