// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IndexedLeaf} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeLowNullifierNotAbove,
    CommitmentTreeLowNullifierNotBelow,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender,
    CommitmentTreeZeroValue
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    AtomicInteropTestUtils,
    FullMerkleWrapper,
    IndexedImtProver,
    MerkleCalldataWrapper
} from "./AtomicInteropTestUtils.sol";

contract L2InteropCommitmentTreeTest is Test {
    L2InteropCommitmentTree internal tree;
    MerkleCalldataWrapper internal merkleWrapper;
    IndexedImtProver internal prover;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        tree = new L2InteropCommitmentTree();
        merkleWrapper = new MerkleCalldataWrapper();
        prover = new IndexedImtProver();
        // This test contract acts as the appender so it can call insert directly.
        tree.initialize(address(this));
    }

    function test_initialize_seedsHeadLeafOnce() public {
        assertEq(tree.appender(), address(this));
        assertEq(tree.leafCount(), 1);
        IndexedLeaf memory head = tree.leafAt(0);
        assertEq(head.value, 0);
        assertEq(head.nextValue, 0);
        assertEq(head.nextIndex, 0);

        vm.expectRevert(CommitmentTreeAlreadyInitialized.selector);
        tree.initialize(address(this));
    }

    function test_initialize_revertsOnZeroAppender() public {
        L2InteropCommitmentTree fresh = new L2InteropCommitmentTree();
        vm.expectRevert(CommitmentTreeZeroAppender.selector);
        fresh.initialize(address(0));
    }

    function test_insert_maintainsSortedLinkedList() public {
        tree.insert(100, 0); // head -> 100
        tree.insert(300, 1); // 100 -> 300
        tree.insert(200, 1); // 100 -> 200 -> 300 (inserted between)

        assertEq(tree.leafCount(), 4);

        // head{0,100,1}
        IndexedLeaf memory head = tree.leafAt(0);
        assertEq(head.nextValue, 100);
        assertEq(head.nextIndex, 1);
        // leaf1 (value 100) now points to 200 at index 3
        IndexedLeaf memory l1 = tree.leafAt(1);
        assertEq(l1.value, 100);
        assertEq(l1.nextValue, 200);
        assertEq(l1.nextIndex, 3);
        // leaf3 (value 200) points to 300 at index 2
        IndexedLeaf memory l3 = tree.leafAt(3);
        assertEq(l3.value, 200);
        assertEq(l3.nextValue, 300);
        assertEq(l3.nextIndex, 2);
        // leaf2 (value 300) is the max
        IndexedLeaf memory l2 = tree.leafAt(2);
        assertEq(l2.value, 300);
        assertEq(l2.nextValue, 0);
    }

    function test_insert_inclusionPathVerifies() public {
        tree.insert(100, 0);
        tree.insert(300, 1);
        tree.insert(200, 1);

        // Mirror the tree into a FullMerkle and check the root + an inclusion path for value 200.
        FullMerkleWrapper mirror = prover.mirror(tree);
        assertEq(mirror.root(), tree.root(), "mirror root matches");

        uint256 idx = prover.indexOfValue(tree, 200);
        bytes32 leafHash = AtomicInteropTestUtils.indexedLeafHash(tree.leafAt(idx));
        bytes32[] memory path = mirror.path(idx);
        assertEq(merkleWrapper.calcRoot(path, idx, leafHash), tree.root(), "inclusion path verifies");
    }

    function test_lowNullifier_bracketsAbsentValues() public {
        tree.insert(100, 0);
        tree.insert(300, 1);
        tree.insert(200, 1);

        assertEq(prover.lowNullifierIndex(tree, 50), 0, "below all -> head");
        assertEq(prover.lowNullifierIndex(tree, 250), 3, "between 200 and 300 -> idx of 200");
        assertEq(prover.lowNullifierIndex(tree, 400), 2, "above all -> idx of 300");
    }

    function test_insert_onlyAppender() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, stranger));
        tree.insert(100, 0);
    }

    function test_insert_revertsOnZeroValue() public {
        vm.expectRevert(CommitmentTreeZeroValue.selector);
        tree.insert(0, 0);
    }

    function test_insert_revertsOnWrongLowNullifier() public {
        tree.insert(100, 0); // head -> 100

        // 150's true low-nullifier is leaf1 (100), not the head: head.nextValue (100) <= 150.
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeLowNullifierNotAbove.selector, 150, 100));
        tree.insert(150, 0);

        // 50 is below leaf1's value, so leaf1 cannot be its low-nullifier.
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeLowNullifierNotBelow.selector, 50, 100));
        tree.insert(50, 1);
    }
}
