// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";

/// @notice Unit tests for DynamicIncrementalMerkleMemory library
contract DynamicIncrementalMerkleMemoryTest is Test {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    bytes32 constant ZERO = bytes32(0);

    // ============ createTree Tests ============

    function test_createTree_initializesArrays() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);

        assertEq(tree._sides.length, 10);
        assertEq(tree._zeros.length, 10);
        assertEq(tree._sidesLengthMemory, 0);
        assertEq(tree._zerosLengthMemory, 0);
        assertFalse(tree._needsRootRecalculation);
    }

    function test_createTree_differentDepths() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree1;
        tree1.createTree(5);
        assertEq(tree1._sides.length, 5);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree2;
        tree2.createTree(20);
        assertEq(tree2._sides.length, 20);
    }

    // ============ setup Tests ============

    function test_setup_initializesTree() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);

        bytes32 initialRoot = tree.setup(ZERO);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree._nextLeafIndex, 0);
        assertEq(tree._zerosLengthMemory, 1);
        assertEq(tree._sidesLengthMemory, 1);
        assertEq(tree._zeros[0], ZERO);
    }

    function test_setup_withCustomZero() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);

        bytes32 customZero = keccak256("custom_zero");
        tree.setup(customZero);

        assertEq(tree._zeros[0], customZero);
    }

    // ============ push Tests ============

    function test_push_singleLeaf() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        (uint256 leafIndex, bytes32 newRoot) = tree.push(leaf);

        assertEq(leafIndex, 0);
        assertEq(tree._nextLeafIndex, 1);
        assertTrue(newRoot != bytes32(0));
    }

    function test_push_twoLeaves() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        (uint256 index1, ) = tree.push(leaf1);
        (uint256 index2, bytes32 newRoot) = tree.push(leaf2);

        assertEq(index1, 0);
        assertEq(index2, 1);
        assertEq(tree._nextLeafIndex, 2);

        // Verify root is hash of two leaves
        bytes32 expectedRoot = Merkle.efficientHash(leaf1, leaf2);
        assertEq(newRoot, expectedRoot);
    }

    function test_push_fourLeaves() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.push(leaf1);
        tree.push(leaf2);
        tree.push(leaf3);
        (, bytes32 newRoot) = tree.push(leaf4);

        // Calculate expected root
        bytes32 hash12 = Merkle.efficientHash(leaf1, leaf2);
        bytes32 hash34 = Merkle.efficientHash(leaf3, leaf4);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash34);

        assertEq(newRoot, expectedRoot);
    }

    function test_push_expandsTree() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        // Push leaves until tree expands
        tree.push(keccak256("leaf1")); // index 0
        uint256 heightBefore = tree.height();

        tree.push(keccak256("leaf2")); // index 1, triggers expansion
        uint256 heightAfter = tree.height();

        assertEq(heightBefore, 0);
        assertEq(heightAfter, 1);
    }

    // ============ pushLazy Tests ============

    function test_pushLazy_singleLeaf() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        uint256 leafIndex = tree.pushLazy(leaf);

        assertEq(leafIndex, 0);
        assertEq(tree._nextLeafIndex, 1);
        // Note: _needsRootRecalculation is set only when we update sides[i] for a left child
        // For the first leaf (index 0), the sides[0] is updated
    }

    function test_pushLazy_multipleLeaves() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        tree.pushLazy(keccak256("leaf1"));
        tree.pushLazy(keccak256("leaf2"));
        tree.pushLazy(keccak256("leaf3"));

        assertEq(tree._nextLeafIndex, 3);
    }

    function test_pushLazy_rootRecalculationOnAccess() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.pushLazy(leaf1);
        tree.pushLazy(leaf2);

        // Root should be recalculated when accessed
        bytes32 computedRoot = tree.root();

        // Compare with push (non-lazy)
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree2;
        tree2.createTree(10);
        tree2.setup(ZERO);
        tree2.push(leaf1);
        (, bytes32 expectedRoot) = tree2.push(leaf2);

        assertEq(computedRoot, expectedRoot);
    }

    // ============ root Tests ============

    function test_root_emptyTree() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 rootValue = tree.root();
        assertEq(rootValue, bytes32(0));
    }

    function test_root_afterPush() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf");
        (, bytes32 pushRoot) = tree.push(leaf);

        bytes32 rootValue = tree.root();
        assertEq(rootValue, pushRoot);
    }

    function test_root_consistentWithPush() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.push(leaf1);
        (, bytes32 lastRoot) = tree.push(leaf2);

        assertEq(tree.root(), lastRoot);
    }

    // ============ height Tests ============

    function test_height_afterSetup() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        assertEq(tree.height(), 0);
    }

    function test_height_increasesOnExpansion() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        // Initial height after setup is 0
        assertEq(tree.height(), 0);

        // First push (index 0) - tree expands when leafIndex == 1 << levels
        // Initially levels = 0 (zerosLengthMemory - 1), so 1 << 0 = 1
        // leafIndex 0 != 1, so no expansion
        tree.push(keccak256("leaf1"));
        assertEq(tree.height(), 0);

        // Second push (index 1) - leafIndex == 1 << 0 = 1, triggers expansion
        tree.push(keccak256("leaf2"));
        assertEq(tree.height(), 1);

        // Third push (index 2) - levels = 1, 1 << 1 = 2, leafIndex == 2, triggers expansion
        tree.push(keccak256("leaf3"));
        assertEq(tree.height(), 2);
    }

    // ============ index Tests ============

    function test_index_afterSetup() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        assertEq(tree.index(), 0);
    }

    function test_index_incrementsOnPush() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        assertEq(tree.index(), 0);

        tree.push(keccak256("leaf1"));
        assertEq(tree.index(), 1);

        tree.push(keccak256("leaf2"));
        assertEq(tree.index(), 2);

        tree.push(keccak256("leaf3"));
        assertEq(tree.index(), 3);
    }

    // ============ extendUntilEnd Tests ============

    function test_extendUntilEnd_emptyTree() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(5);
        tree.setup(ZERO);

        tree.extendUntilEnd();

        assertEq(tree._sidesLengthMemory, 5);
        assertEq(tree._zerosLengthMemory, 5);
        assertFalse(tree._needsRootRecalculation);
    }

    function test_extendUntilEnd_partiallyFilledTree() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(5);
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        tree.extendUntilEnd();

        assertEq(tree._sidesLengthMemory, 5);
        assertEq(tree._zerosLengthMemory, 5);
    }

    // ============ Fuzz Tests ============

    function testFuzz_push_incrementsIndex(uint8 numPushes) public pure {
        vm.assume(numPushes > 0 && numPushes <= 50);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        for (uint256 i = 0; i < numPushes; i++) {
            tree.push(keccak256(abi.encodePacked(i)));
        }

        assertEq(tree.index(), numPushes);
    }

    function testFuzz_pushLazy_matchesPush(bytes32 leaf1, bytes32 leaf2) public pure {
        // Test with push
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree1;
        tree1.createTree(10);
        tree1.setup(ZERO);
        tree1.push(leaf1);
        (, bytes32 expectedRoot) = tree1.push(leaf2);

        // Test with pushLazy
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree2;
        tree2.createTree(10);
        tree2.setup(ZERO);
        tree2.pushLazy(leaf1);
        tree2.pushLazy(leaf2);
        bytes32 lazyRoot = tree2.root();

        assertEq(lazyRoot, expectedRoot);
    }

    // ============ Integration Tests ============

    function test_fullWorkflow() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        // Push some leaves
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        (uint256 idx1, ) = tree.push(leaf1);
        (uint256 idx2, ) = tree.push(leaf2);
        (uint256 idx3, ) = tree.push(leaf3);
        (uint256 idx4, bytes32 finalRoot) = tree.push(leaf4);

        // Verify indices
        assertEq(idx1, 0);
        assertEq(idx2, 1);
        assertEq(idx3, 2);
        assertEq(idx4, 3);

        // Verify root matches computed value
        assertEq(tree.root(), finalRoot);

        // Verify state - height increases with tree expansion
        // Index 1 triggers expansion (height 0->1), index 2 triggers expansion (height 1->2)
        // After 4 leaves, height is 2
        assertEq(tree.index(), 4);
        assertEq(tree.height(), 2);
    }

    function test_mixedPushAndPushLazy() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(10);
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.push(leaf1);
        tree.pushLazy(leaf2);
        tree.push(leaf3);
        tree.pushLazy(leaf4);

        bytes32 rootValue = tree.root();

        // Compare with all push
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree2;
        tree2.createTree(10);
        tree2.setup(ZERO);
        tree2.push(leaf1);
        tree2.push(leaf2);
        tree2.push(leaf3);
        (, bytes32 expectedRoot) = tree2.push(leaf4);

        assertEq(rootValue, expectedRoot);
    }
}
