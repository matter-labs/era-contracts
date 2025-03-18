// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityTreeSharedTest, PriorityOpsBatchInfo} from "./_PriorityTree_Shared.t.sol";
import {PriorityTreeCommitment} from "contracts/common/Config.sol";
import {NotHistoricalRoot} from "contracts/state-transition/L1StateTransitionErrors.sol";

bytes32 constant ZERO_LEAF_HASH = keccak256("");

contract PriorityTreeTest is PriorityTreeSharedTest {
    function test_gets() public {
        assertEq(0, priorityTree.getSize());
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(0, priorityTree.getTotalPriorityTxs());
        assertEq(bytes32(0), priorityTree.getRoot());
    }

    function test_push() public {
        bytes32 leaf1 = keccak256(abi.encode(1));
        bytes32 leaf2 = keccak256(abi.encode(2));

        priorityTree.push(leaf1);

        assertEq(1, priorityTree.getSize());
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(1, priorityTree.getTotalPriorityTxs());
        assertEq(leaf1, priorityTree.getRoot());

        priorityTree.push(leaf2);

        assertEq(2, priorityTree.getSize());
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(2, priorityTree.getTotalPriorityTxs());

        bytes32 expectedRoot = keccak256(abi.encode(leaf1, leaf2));
        assertEq(expectedRoot, priorityTree.getRoot());
    }

    function test_processEmptyBatch() public {
        pushMockEntries(3);

        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        priorityTree.processBatch(
            PriorityOpsBatchInfo({
                leftPath: new bytes32[](0),
                rightPath: new bytes32[](0),
                itemHashes: new bytes32[](0)
            })
        );

        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
    }

    function test_processBatch() public {
        bytes32[] memory leaves = pushMockEntries(3);
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());

        // 2 batches with: 1 tx, 2 txs.

        bytes32[] memory leftPath = new bytes32[](2);
        bytes32[] memory rightPath = new bytes32[](2);
        rightPath[0] = leaves[1];
        rightPath[1] = keccak256(abi.encode(leaves[2], ZERO_LEAF_HASH));
        bytes32[] memory batch1 = new bytes32[](1);
        batch1[0] = leaves[0];

        priorityTree.processBatch(PriorityOpsBatchInfo({leftPath: leftPath, rightPath: rightPath, itemHashes: batch1}));

        assertEq(1, priorityTree.getFirstUnprocessedPriorityTx());

        leftPath[0] = leaves[0];
        rightPath[0] = ZERO_LEAF_HASH;
        rightPath[1] = bytes32(0);
        bytes32[] memory batch2 = new bytes32[](2);
        batch2[0] = leaves[1];
        batch2[1] = leaves[2];

        priorityTree.processBatch(PriorityOpsBatchInfo({leftPath: leftPath, rightPath: rightPath, itemHashes: batch2}));

        assertEq(3, priorityTree.getFirstUnprocessedPriorityTx());
    }

    function test_processBatch_shouldRevert() public {
        bytes32[] memory itemHashes = pushMockEntries(3);

        vm.expectRevert(NotHistoricalRoot.selector);
        priorityTree.processBatch(
            PriorityOpsBatchInfo({leftPath: new bytes32[](2), rightPath: new bytes32[](2), itemHashes: itemHashes})
        );
    }

    function test_commitDecommit() public {
        pushMockEntries(3);
        bytes32 root = priorityTree.getRoot();

        PriorityTreeCommitment memory commitment = priorityTree.getCommitment();
        priorityTree.initFromCommitment(commitment);

        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(3, priorityTree.getTotalPriorityTxs());
        assertEq(root, priorityTree.getRoot());
        assertEq(ZERO_LEAF_HASH, priorityTree.getZero());
    }
}
