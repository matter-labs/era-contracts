// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    PriorityOpsBatchInfo,
    PriorityTree,
    ZERO_LEAF_HASH
} from "contracts/state-transition/libraries/PriorityTree.sol";
import {PriorityTreeCommitment} from "contracts/common/Config.sol";
import {
    InvalidCommitment,
    InvalidNextLeafIndex,
    InvalidStartIndex,
    InvalidUnprocessedIndex,
    NotHistoricalRoot
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Unit tests for PriorityTree library
contract PriorityTreeLibraryTest is Test {
    using PriorityTree for PriorityTree.Tree;

    PriorityTree.Tree internal tree;
    PriorityTree.Tree internal restoredTree;

    // ============ setup Tests ============

    function test_setup_initializesTree() public {
        tree.setup(0);

        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
        assertEq(tree.getTotalPriorityTxs(), 0);
        assertEq(tree.getSize(), 0);
        assertEq(tree.getRoot(), bytes32(0));
        assertTrue(tree.isHistoricalRoot(bytes32(0)));
    }

    function test_setup_withNonZeroStartIndex() public {
        tree.setup(100);

        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
        assertEq(tree.getTotalPriorityTxs(), 100);
        assertEq(tree.getSize(), 0);
    }

    // ============ push Tests ============

    function test_push() public {
        tree.setup(0);
        bytes32 leaf1 = keccak256(abi.encode(1));
        bytes32 leaf2 = keccak256(abi.encode(2));

        tree.push(leaf1);

        assertEq(tree.getSize(), 1);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
        assertEq(tree.getTotalPriorityTxs(), 1);
        assertEq(tree.getRoot(), leaf1);

        tree.push(leaf2);

        assertEq(tree.getSize(), 2);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
        assertEq(tree.getTotalPriorityTxs(), 2);
        assertEq(tree.getRoot(), keccak256(abi.encode(leaf1, leaf2)));
    }

    // ============ getRoot and isHistoricalRoot Tests ============

    function test_isHistoricalRoot_allRootsAreHistorical() public {
        tree.setup(0);

        bytes32 root1 = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(root1));

        tree.push(keccak256("tx1"));
        bytes32 root2 = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(root2));

        tree.push(keccak256("tx2"));
        bytes32 root3 = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(root3));

        // All historical roots should still be valid
        assertTrue(tree.isHistoricalRoot(root1));
        assertTrue(tree.isHistoricalRoot(root2));
        assertTrue(tree.isHistoricalRoot(root3));
    }

    function test_isHistoricalRoot_unknownRootReturnsFalse() public {
        tree.setup(0);

        bytes32 randomRoot = keccak256("random");
        assertFalse(tree.isHistoricalRoot(randomRoot));
    }

    // ============ skipUntil Tests ============

    function test_skipUntil_doesNothingIfBelowStartIndex() public {
        tree.setup(100);

        tree.push(keccak256("tx1"));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);

        tree.skipUntil(50); // Below start index

        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
    }

    function test_skipUntil_doesNothingIfAlreadyProcessed() public {
        tree.setup(0);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));

        tree.skipUntil(2);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 2);

        tree.skipUntil(1); // Already processed

        assertEq(tree.getFirstUnprocessedPriorityTx(), 2);
    }

    // ============ processBatch Tests ============

    function test_processBatch_emptyBatch() public {
        tree.setup(0);
        _pushMockEntries(3);

        tree.processBatch(
            PriorityOpsBatchInfo({
                leftPath: new bytes32[](0),
                rightPath: new bytes32[](0),
                itemHashes: new bytes32[](0)
            })
        );

        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
    }

    function test_processBatch() public {
        tree.setup(0);
        bytes32[] memory leaves = _pushMockEntries(3);

        // 2 batches with: 1 tx, 2 txs.
        bytes32[] memory leftPath = new bytes32[](2);
        bytes32[] memory rightPath = new bytes32[](2);
        rightPath[0] = leaves[1];
        rightPath[1] = keccak256(abi.encode(leaves[2], ZERO_LEAF_HASH));
        bytes32[] memory batch1 = new bytes32[](1);
        batch1[0] = leaves[0];

        tree.processBatch(PriorityOpsBatchInfo({leftPath: leftPath, rightPath: rightPath, itemHashes: batch1}));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 1);

        leftPath[0] = leaves[0];
        rightPath[0] = ZERO_LEAF_HASH;
        rightPath[1] = bytes32(0);
        bytes32[] memory batch2 = new bytes32[](2);
        batch2[0] = leaves[1];
        batch2[1] = leaves[2];

        tree.processBatch(PriorityOpsBatchInfo({leftPath: leftPath, rightPath: rightPath, itemHashes: batch2}));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 3);
    }

    function test_processBatch_revertsOnUnknownRoot() public {
        tree.setup(0);
        bytes32[] memory itemHashes = _pushMockEntries(3);

        vm.expectRevert(
            abi.encodeWithSelector(
                NotHistoricalRoot.selector,
                0x9916b82f0d1215e1cf93fdcf4c628eef02a88b920e9f8adf6abbd1a42cf9414c
            )
        );
        tree.processBatch(
            PriorityOpsBatchInfo({leftPath: new bytes32[](2), rightPath: new bytes32[](2), itemHashes: itemHashes})
        );
    }

    // ============ getCommitment and initFromCommitment Tests ============

    function test_initFromCommitment_restoresTree() public {
        tree.setup(10);
        _pushMockEntries(3);
        tree.skipUntil(11);
        bytes32 root = tree.getRoot();

        restoredTree.initFromCommitment(tree.getCommitment());

        assertEq(restoredTree.getFirstUnprocessedPriorityTx(), 11);
        assertEq(restoredTree.getTotalPriorityTxs(), 13);
        assertEq(restoredTree.getRoot(), root);
        assertTrue(restoredTree.isHistoricalRoot(root));
        assertEq(restoredTree.tree._zeros[0], ZERO_LEAF_HASH);
    }

    function test_initFromCommitment_revertsOnEmptySides() public {
        PriorityTreeCommitment memory commitment;
        commitment.sides = new bytes32[](0);

        vm.expectRevert(InvalidCommitment.selector);
        tree.initFromCommitment(commitment);
    }

    // ============ l1Reinit Tests ============

    function test_l1Reinit_validReinit() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.push(keccak256("tx3"));

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 2;
        commitment.nextLeafIndex = 3;
        commitment.sides = new bytes32[](1);

        tree.l1Reinit(commitment);

        assertEq(tree.unprocessedIndex, 2);
    }

    function test_l1Reinit_revertsOnInvalidStartIndex() public {
        tree.setup(10);

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 20; // Different from tree's start index
        commitment.unprocessedIndex = 0;
        commitment.nextLeafIndex = 0;
        commitment.sides = new bytes32[](1);

        vm.expectRevert(abi.encodeWithSelector(InvalidStartIndex.selector, 10, 20));
        tree.l1Reinit(commitment);
    }

    function test_l1Reinit_revertsOnInvalidUnprocessedIndex() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.skipUntil(11); // unprocessedIndex = 1

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 0; // Less than current unprocessedIndex
        commitment.nextLeafIndex = 1;
        commitment.sides = new bytes32[](1);

        vm.expectRevert(abi.encodeWithSelector(InvalidUnprocessedIndex.selector, 1, 0));
        tree.l1Reinit(commitment);
    }

    function test_l1Reinit_revertsOnInvalidNextLeafIndex() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 0;
        commitment.nextLeafIndex = 5; // Greater than tree's nextLeafIndex (2)
        commitment.sides = new bytes32[](1);

        vm.expectRevert(abi.encodeWithSelector(InvalidNextLeafIndex.selector, 2, 5));
        tree.l1Reinit(commitment);
    }

    // ============ checkGWReinit Tests ============

    function test_checkGWReinit_validCheck() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 0;
        commitment.nextLeafIndex = 2; // Greater than or equal to tree's

        tree.checkGWReinit(commitment);
    }

    function test_checkGWReinit_revertsOnInvalidStartIndex() public {
        tree.setup(10);

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 20;
        commitment.unprocessedIndex = 0;
        commitment.nextLeafIndex = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidStartIndex.selector, 10, 20));
        tree.checkGWReinit(commitment);
    }

    function test_checkGWReinit_revertsOnInvalidUnprocessedIndex() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.skipUntil(11); // unprocessedIndex = 1

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 0; // Less than current
        commitment.nextLeafIndex = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidUnprocessedIndex.selector, 1, 0));
        tree.checkGWReinit(commitment);
    }

    function test_checkGWReinit_revertsOnInvalidNextLeafIndex() public {
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));

        PriorityTreeCommitment memory commitment;
        commitment.startIndex = 10;
        commitment.unprocessedIndex = 0;
        commitment.nextLeafIndex = 1; // Less than tree's nextLeafIndex (2)

        vm.expectRevert(abi.encodeWithSelector(InvalidNextLeafIndex.selector, 2, 1));
        tree.checkGWReinit(commitment);
    }

    // ============ Fuzz Tests ============

    function testFuzz_push_maintainsCorrectCounts(uint8 _numOps) public {
        vm.assume(_numOps > 0 && _numOps <= 50);

        tree.setup(0);

        for (uint256 i = 0; i < _numOps; i++) {
            tree.push(keccak256(abi.encodePacked(i)));
        }

        assertEq(tree.getTotalPriorityTxs(), _numOps);
        assertEq(tree.getSize(), _numOps);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
    }

    function testFuzz_skipUntil_maintainsCorrectState(uint8 _numOps, uint8 _skipTo) public {
        vm.assume(_numOps > 0 && _numOps <= 50);
        vm.assume(_skipTo <= _numOps);

        tree.setup(0);

        for (uint256 i = 0; i < _numOps; i++) {
            tree.push(keccak256(abi.encodePacked(i)));
        }

        tree.skipUntil(_skipTo);

        assertEq(tree.getFirstUnprocessedPriorityTx(), _skipTo);
        assertEq(tree.getSize(), _numOps - _skipTo);
    }

    // ============ Integration Tests ============

    function test_fullLifecycle() public {
        tree.setup(100);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
        assertEq(tree.getTotalPriorityTxs(), 100);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.push(keccak256("tx3"));
        assertEq(tree.getTotalPriorityTxs(), 103);
        assertEq(tree.getSize(), 3);

        tree.skipUntil(102);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 102);
        assertEq(tree.getSize(), 1);

        PriorityTreeCommitment memory commitment = tree.getCommitment();
        assertEq(commitment.startIndex, 100);
        assertEq(commitment.unprocessedIndex, 2);
        assertEq(commitment.nextLeafIndex, 3);
    }

    // ============ Helper Functions ============

    function _pushMockEntries(uint256 _count) internal returns (bytes32[] memory hashes) {
        hashes = new bytes32[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            hashes[i] = keccak256(abi.encode(i));
            tree.push(hashes[i]);
        }
    }
}
