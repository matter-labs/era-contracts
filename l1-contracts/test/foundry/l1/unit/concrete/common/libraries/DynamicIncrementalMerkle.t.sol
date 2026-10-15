// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";

/// @notice Unit tests for DynamicIncrementalMerkle library
contract DynamicIncrementalMerkleTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    DynamicIncrementalMerkle.Bytes32PushTree internal tree;

    bytes32 internal constant ZERO = bytes32(uint256(0));

    // ============ setup Tests ============

    function test_setup_initializes_correctly() public {
        bytes32 initialRoot = tree.setup(ZERO);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree.height(), 0);
        assertEq(tree.root(), bytes32(0));
    }

    // ============ push Tests ============

    function test_push_single_element() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        (uint256 index, bytes32 newRoot) = tree.push(leaf);

        assertEq(index, 0);
        assertEq(newRoot, leaf);
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
        assertEq(newRoot, Merkle.efficientHash(leaf1, leaf2));
        assertEq(tree.root(), newRoot);
        assertEq(tree.height(), 1);
    }

    // ============ height Tests ============

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

        assertEq(tree._nextLeafIndex, 0);
        assertEq(tree._sides.length, 0);
        assertEq(tree._zeros.length, 0);
    }

    // ============ reset Tests ============

    function test_reset_clears_and_reinitializes() public {
        tree.setup(ZERO);

        tree.push(keccak256("leaf1"));
        tree.push(keccak256("leaf2"));
        tree.push(keccak256("leaf3"));

        bytes32 newZero = keccak256("new_zero");
        bytes32 initialRoot = tree.reset(newZero);

        assertEq(initialRoot, bytes32(0));
        assertEq(tree.root(), bytes32(0));
        assertEq(tree._nextLeafIndex, 0);
        assertEq(tree.height(), 0);
        assertEq(tree._zeros.length, 1);
        assertEq(tree._zeros[0], newZero);

        tree.push(bytes32(uint256(42)));
        assertEq(tree.root(), bytes32(uint256(42)));
    }

    // ============ extendUntilEnd Tests ============

    function test_extendUntilEnd_empty_tree() public {
        tree.setup(ZERO);

        tree.extendUntilEnd(5);

        assertEq(tree.height(), 4);
        assertEq(tree.root(), tree._zeros[4]);
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

        for (uint256 i = 0; i < 8; i++) {
            tree.push(keccak256(abi.encode(i)));
        }

        uint256 currentHeight = tree.height();
        assertEq(currentHeight, 3);

        // Extend to same or smaller depth should be no-op
        tree.extendUntilEnd(3);
        assertEq(tree.height(), currentHeight);
    }

    function test_extendUntilEnd_pads_root_with_zeros() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        tree.push(leaf1);
        tree.push(leaf2);

        tree.extendUntilEnd(3);

        bytes32 expectedRoot = Merkle.efficientHash(
            Merkle.efficientHash(leaf1, leaf2),
            Merkle.efficientHash(ZERO, ZERO)
        );
        assertEq(tree.root(), expectedRoot);
    }

    // ============ Gas and Stress Tests ============

    function test_push_many_elements() public {
        tree.setup(ZERO);

        for (uint256 i = 0; i < 64; i++) {
            (uint256 index, ) = tree.push(keccak256(abi.encode(i)));
            assertEq(index, i);
        }

        // After 64 elements, tree should be height 6
        assertEq(tree.height(), 6);
    }
}
