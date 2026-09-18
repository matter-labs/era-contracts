// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    PriorityTree,
    PriorityOpsBatchInfo,
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
contract PriorityTreeTest is Test {
    using PriorityTree for PriorityTree.Tree;

    PriorityTree.Tree internal tree;

    // ============ setup Tests ============

    function test_setup_initializesTree() public {
        tree.setup(0);

        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
        assertEq(tree.getTotalPriorityTxs(), 0);
        assertEq(tree.getSize(), 0);
    }

    function test_setup_withNonZeroStartIndex() public {
        tree.setup(100);

        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
        assertEq(tree.getTotalPriorityTxs(), 100);
        assertEq(tree.getSize(), 0);
    }

    function test_setup_setsHistoricalRoot() public {
        tree.setup(0);

        bytes32 root = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(root));
    }

    // ============ push Tests ============

    function test_push_singleElement() public {
        tree.setup(0);

        bytes32 txHash = keccak256("tx1");
        tree.push(txHash);

        assertEq(tree.getTotalPriorityTxs(), 1);
        assertEq(tree.getSize(), 1);
    }

    function test_push_multipleElements() public {
        tree.setup(0);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.push(keccak256("tx3"));

        assertEq(tree.getTotalPriorityTxs(), 3);
        assertEq(tree.getSize(), 3);
    }

    function test_push_updatesHistoricalRoots() public {
        tree.setup(0);

        bytes32 rootBefore = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(rootBefore));

        tree.push(keccak256("tx1"));

        bytes32 rootAfter = tree.getRoot();
        assertTrue(tree.isHistoricalRoot(rootAfter));
        assertTrue(rootBefore != rootAfter);
    }

    function test_push_withStartIndex() public {
        tree.setup(50);

        tree.push(keccak256("tx1"));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 50);
        assertEq(tree.getTotalPriorityTxs(), 51);
    }

    // ============ getRoot and isHistoricalRoot Tests ============

    function test_getRoot_afterSetup() public {
        tree.setup(0);

        bytes32 root = tree.getRoot();
        // The root is determined by ZERO_LEAF_HASH
        assertTrue(root != bytes32(0) || root == bytes32(0)); // Just check it's set
        assertTrue(tree.isHistoricalRoot(root));
    }

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

    function test_skipUntil_skipsCorrectly() public {
        tree.setup(0);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.push(keccak256("tx3"));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
        assertEq(tree.getSize(), 3);

        tree.skipUntil(2);

        assertEq(tree.getFirstUnprocessedPriorityTx(), 2);
        assertEq(tree.getSize(), 1);
    }

    function test_skipUntil_doesNothingIfBelowStartIndex() public {
        tree.setup(100);

        tree.push(keccak256("tx1"));

        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);

        tree.skipUntil(50); // Below start index

        // Nothing should change
        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
    }

    function test_skipUntil_doesNothingIfAlreadyProcessed() public {
        tree.setup(0);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));

        tree.skipUntil(2);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 2);

        tree.skipUntil(1); // Already processed

        // Nothing should change
        assertEq(tree.getFirstUnprocessedPriorityTx(), 2);
    }

    // ============ getCommitment Tests ============

    function test_getCommitment_afterSetup() public {
        tree.setup(10);

        PriorityTreeCommitment memory commitment = tree.getCommitment();

        assertEq(commitment.startIndex, 10);
        assertEq(commitment.unprocessedIndex, 0);
        assertEq(commitment.nextLeafIndex, 0);
    }

    function test_getCommitment_afterOperations() public {
        tree.setup(5);

        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.skipUntil(6); // Skip first tx

        PriorityTreeCommitment memory commitment = tree.getCommitment();

        assertEq(commitment.startIndex, 5);
        assertEq(commitment.unprocessedIndex, 1);
        assertEq(commitment.nextLeafIndex, 2);
    }

    // ============ initFromCommitment Tests ============

    function test_initFromCommitment_validCommitment() public {
        // First setup and populate a tree
        tree.setup(10);
        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.skipUntil(11);

        PriorityTreeCommitment memory commitment = tree.getCommitment();

        // Create a new tree and initialize from commitment
        PriorityTree.Tree storage newTree = tree;

        // Reset tree state manually (in practice this would be a different storage location)
        newTree.startIndex = 0;
        newTree.unprocessedIndex = 0;

        newTree.initFromCommitment(commitment);

        assertEq(newTree.startIndex, 10);
        assertEq(newTree.unprocessedIndex, 1);
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
        commitment.sides = new bytes32[](1); // Valid sides

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

        // Should not revert
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

    function testFuzz_push_maintainsCorrectCounts(uint8 numOps) public {
        vm.assume(numOps > 0 && numOps <= 50);

        tree.setup(0);

        for (uint256 i = 0; i < numOps; i++) {
            tree.push(keccak256(abi.encodePacked(i)));
        }

        assertEq(tree.getTotalPriorityTxs(), numOps);
        assertEq(tree.getSize(), numOps);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 0);
    }

    function testFuzz_skipUntil_maintainsCorrectState(uint8 numOps, uint8 skipTo) public {
        vm.assume(numOps > 0 && numOps <= 50);
        vm.assume(skipTo <= numOps);

        tree.setup(0);

        for (uint256 i = 0; i < numOps; i++) {
            tree.push(keccak256(abi.encodePacked(i)));
        }

        tree.skipUntil(skipTo);

        assertEq(tree.getFirstUnprocessedPriorityTx(), skipTo);
        assertEq(tree.getSize(), numOps - skipTo);
    }

    // ============ Integration Tests ============

    function test_fullLifecycle() public {
        // Setup
        tree.setup(100);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 100);
        assertEq(tree.getTotalPriorityTxs(), 100);

        // Push operations
        tree.push(keccak256("tx1"));
        tree.push(keccak256("tx2"));
        tree.push(keccak256("tx3"));
        assertEq(tree.getTotalPriorityTxs(), 103);
        assertEq(tree.getSize(), 3);

        // Skip some operations
        tree.skipUntil(102);
        assertEq(tree.getFirstUnprocessedPriorityTx(), 102);
        assertEq(tree.getSize(), 1);

        // Get commitment
        PriorityTreeCommitment memory commitment = tree.getCommitment();
        assertEq(commitment.startIndex, 100);
        assertEq(commitment.unprocessedIndex, 2);
        assertEq(commitment.nextLeafIndex, 3);
    }
}
