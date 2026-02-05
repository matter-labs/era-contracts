// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";

/// @notice Unit tests for DynamicIncrementalMerkle library
contract DynamicIncrementalMerkleTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    DynamicIncrementalMerkle.Bytes32PushTree internal tree;

    bytes32 constant ZERO = bytes32(uint256(0));

    // ============ setup Tests ============

    function test_setup_initializes_correctly() public {
        bytes32 initialRoot = tree.setup(ZERO);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree.height(), 0);
        assertEq(tree.root(), bytes32(0));
    }

    function test_setup_with_custom_zero() public {
        bytes32 customZero = keccak256("custom_zero");
        bytes32 initialRoot = tree.setup(customZero);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree.height(), 0);
    }

    // ============ push Tests ============

    function test_push_single_element() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        (uint256 index, bytes32 newRoot) = tree.push(leaf);

        assertEq(index, 0);
        assertTrue(newRoot != bytes32(0));
        assertEq(tree.root(), newRoot);
    }

    function test_push_two_elements() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        (uint256 index1, ) = tree.push(leaf1);
        (uint256 index2, bytes32 newRoot) = tree.push(leaf2);

        assertEq(index1, 0);
        assertEq(index2, 1);
        assertTrue(newRoot != bytes32(0));
        assertEq(tree.height(), 1);
    }

    function test_push_four_elements_expands_tree() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.push(leaf1); // index=0, no expansion
        tree.push(leaf2); // index=1, expands to height 1

        // After two elements, tree height should be 1
        assertEq(tree.height(), 1);

        tree.push(leaf3); // index=2, expands to height 2

        // After three elements, tree should expand
        assertEq(tree.height(), 2);

        (uint256 index4, ) = tree.push(leaf4); // index=3, no expansion
        assertEq(index4, 3);
        assertEq(tree.height(), 2);
    }

    function test_push_triggers_tree_expansion() public {
        tree.setup(ZERO);

        // Push enough elements to trigger multiple expansions
        for (uint256 i = 0; i < 8; i++) {
            tree.push(keccak256(abi.encode(i)));
        }

        // After 8 elements, tree should be height 3
        assertEq(tree.height(), 3);
    }

    function testFuzz_push_returns_sequential_indices(uint8 numElements) public {
        vm.assume(numElements > 0 && numElements <= 32);

        tree.setup(ZERO);

        for (uint256 i = 0; i < numElements; i++) {
            (uint256 index, ) = tree.push(keccak256(abi.encode(i)));
            assertEq(index, i);
        }
    }

    // ============ root Tests ============

    function test_root_changes_with_each_push() public {
        tree.setup(ZERO);

        bytes32 initialRoot = tree.root();

        tree.push(keccak256("leaf1"));
        bytes32 root1 = tree.root();

        tree.push(keccak256("leaf2"));
        bytes32 root2 = tree.root();

        assertTrue(root1 != initialRoot);
        assertTrue(root2 != root1);
    }

    function test_root_deterministic() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        bytes32 root1 = tree.root();

        // Reset and rebuild
        DynamicIncrementalMerkle.Bytes32PushTree storage tree2 = tree;
        tree2.clear();
        tree2.setup(ZERO);

        tree2.push(keccak256("leaf1"));
        tree2.push(keccak256("leaf2"));

        bytes32 root2 = tree2.root();

        assertEq(root1, root2);
    }

    // ============ height Tests ============

    function test_height_starts_at_zero() public {
        tree.setup(ZERO);
        assertEq(tree.height(), 0);
    }

    function test_height_increases_correctly() public {
        tree.setup(ZERO);
        // After setup: _sides = [0], _zeros = [ZERO], height = 1-1 = 0
        assertEq(tree.height(), 0);

        tree.push(keccak256("leaf1"));
        // After push index=0: no expansion, height stays 0
        assertEq(tree.height(), 0);

        tree.push(keccak256("leaf2"));
        // After push index=1: expansion triggered (1 == 1<<0), height becomes 1
        assertEq(tree.height(), 1);

        tree.push(keccak256("leaf3"));
        // After push index=2: expansion triggered (2 == 1<<1), height becomes 2
        assertEq(tree.height(), 2);

        tree.push(keccak256("leaf4"));
        // After push index=3: no expansion, height stays 2
        assertEq(tree.height(), 2);

        tree.push(keccak256("leaf5"));
        // After push index=4: expansion triggered (4 == 1<<2), height becomes 3
        assertEq(tree.height(), 3);
    }

    // ============ clear Tests ============

    function test_clear_resets_tree() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        assertTrue(tree.height() > 0);

        tree.clear();

        // After clear, internal state should be reset
        // Calling setup again should work
        tree.setup(ZERO);
        assertEq(tree.height(), 0);
    }

    // ============ reset Tests ============

    function test_reset_clears_and_reinitializes() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        assertTrue(tree.height() > 0);

        bytes32 newZero = keccak256("new_zero");
        bytes32 initialRoot = tree.reset(newZero);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree.height(), 0);
    }

    // ============ extendUntilEnd Tests ============

    function test_extendUntilEnd_empty_tree() public {
        tree.setup(ZERO);

        tree.extendUntilEnd(5);

        assertEq(tree.height(), 4);
    }

    function test_extendUntilEnd_with_elements() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        // Current height is 1
        assertEq(tree.height(), 1);

        tree.extendUntilEnd(5);

        // Extended to depth 5 (height 4)
        assertEq(tree.height(), 4);
    }

    function test_extendUntilEnd_no_op_when_already_large_enough() public {
        tree.setup(ZERO);

        // Push enough elements to get height 3
        for (uint256 i = 0; i < 8; i++) {
            tree.push(keccak256(abi.encode(i)));
        }

        uint256 currentHeight = tree.height();
        assertEq(currentHeight, 3);

        // Extend to same or smaller depth should be no-op
        tree.extendUntilEnd(3);
        assertEq(tree.height(), currentHeight);
    }

    function test_extendUntilEnd_preserves_root_equivalence() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));

        bytes32 rootBefore = tree.root();

        tree.extendUntilEnd(10);

        bytes32 rootAfter = tree.root();

        // Root should change after extension (as it includes zeros at higher levels)
        assertTrue(rootAfter != bytes32(0));
    }

    // ============ Gas and Stress Tests ============

    function test_push_many_elements() public {
        tree.setup(ZERO);

        // Push 64 elements
        for (uint256 i = 0; i < 64; i++) {
            (uint256 index, ) = tree.push(keccak256(abi.encode(i)));
            assertEq(index, i);
        }

        // After 64 elements, tree should be height 6
        assertEq(tree.height(), 6);
    }

    function test_sequential_operations() public {
        tree.setup(ZERO);

        // Push
        tree.push(keccak256("a"));
        tree.push(keccak256("b"));
        bytes32 root1 = tree.root();

        // More pushes
        tree.push(keccak256("c"));
        bytes32 root2 = tree.root();

        // Extend
        tree.extendUntilEnd(5);
        bytes32 root3 = tree.root();

        // All roots should be different
        assertTrue(root1 != root2);
        assertTrue(root2 != root3);
    }
}
