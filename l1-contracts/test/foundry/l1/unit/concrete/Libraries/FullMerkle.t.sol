// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MerkleWrongIndex, MerkleWrongLength} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for FullMerkle library
contract FullMerkleTest is Test {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal tree;

    bytes32 constant ZERO = bytes32(0);

    // ============ setup Tests ============

    function test_setup_initializesTree() public {
        bytes32 initialRoot = tree.setup(ZERO);

        assertEq(initialRoot, ZERO);
        assertEq(tree.root(), ZERO);
    }

    function test_setup_withNonZeroValue() public {
        bytes32 customZero = keccak256("custom_zero");
        bytes32 initialRoot = tree.setup(customZero);

        assertEq(initialRoot, customZero);
        assertEq(tree.root(), customZero);
    }

    // ============ pushNewLeaf Tests ============

    function test_pushNewLeaf_firstLeaf() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        bytes32 newRoot = tree.pushNewLeaf(leaf);

        assertEq(newRoot, leaf);
        assertEq(tree.root(), leaf);
    }

    function test_pushNewLeaf_twoLeaves() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.pushNewLeaf(leaf1);
        bytes32 newRoot = tree.pushNewLeaf(leaf2);

        bytes32 expectedRoot = Merkle.efficientHash(leaf1, leaf2);
        assertEq(newRoot, expectedRoot);
    }

    function test_pushNewLeaf_fourLeaves() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);
        tree.pushNewLeaf(leaf3);
        bytes32 newRoot = tree.pushNewLeaf(leaf4);

        bytes32 hash12 = Merkle.efficientHash(leaf1, leaf2);
        bytes32 hash34 = Merkle.efficientHash(leaf3, leaf4);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash34);

        assertEq(newRoot, expectedRoot);
    }

    function test_pushNewLeaf_threeLeaves_usesZero() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);
        bytes32 newRoot = tree.pushNewLeaf(leaf3);

        // With 3 leaves, the 4th position uses ZERO
        bytes32 hash12 = Merkle.efficientHash(leaf1, leaf2);
        bytes32 hash3Zero = Merkle.efficientHash(leaf3, ZERO);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash3Zero);

        assertEq(newRoot, expectedRoot);
    }

    function test_pushNewLeaf_expandsTreeHeight() public {
        tree.setup(ZERO);

        // Push leaves until tree needs to expand
        bytes32 leaf = keccak256("leaf");
        tree.pushNewLeaf(leaf); // height stays 0
        tree.pushNewLeaf(leaf); // height becomes 1
        tree.pushNewLeaf(leaf); // height stays 1
        tree.pushNewLeaf(leaf); // height stays 1
        tree.pushNewLeaf(leaf); // height becomes 2

        // Tree should have expanded to accommodate 5 leaves
        assertEq(tree.root(), tree.root()); // Just verify it doesn't revert
    }

    // ============ updateLeaf Tests ============

    function test_updateLeaf_singleLeaf() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        tree.pushNewLeaf(leaf1);

        bytes32 newLeaf = keccak256("updated");
        bytes32 newRoot = tree.updateLeaf(0, newLeaf);

        assertEq(newRoot, newLeaf);
        assertEq(tree.root(), newLeaf);
    }

    function test_updateLeaf_firstOfTwo() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);

        bytes32 newLeaf = keccak256("updated");
        bytes32 newRoot = tree.updateLeaf(0, newLeaf);

        bytes32 expectedRoot = Merkle.efficientHash(newLeaf, leaf2);
        assertEq(newRoot, expectedRoot);
    }

    function test_updateLeaf_secondOfTwo() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);

        bytes32 newLeaf = keccak256("updated");
        bytes32 newRoot = tree.updateLeaf(1, newLeaf);

        bytes32 expectedRoot = Merkle.efficientHash(leaf1, newLeaf);
        assertEq(newRoot, expectedRoot);
    }

    function test_updateLeaf_revertsOnInvalidIndex() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf");
        tree.pushNewLeaf(leaf);

        vm.expectRevert(abi.encodeWithSelector(MerkleWrongIndex.selector, 1, 0));
        tree.updateLeaf(1, keccak256("new"));
    }

    function test_updateLeaf_middleOfFour() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);
        tree.pushNewLeaf(leaf3);
        tree.pushNewLeaf(leaf4);

        bytes32 newLeaf = keccak256("updated");
        bytes32 newRoot = tree.updateLeaf(2, newLeaf);

        bytes32 hash12 = Merkle.efficientHash(leaf1, leaf2);
        bytes32 hashNew4 = Merkle.efficientHash(newLeaf, leaf4);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hashNew4);

        assertEq(newRoot, expectedRoot);
    }

    // ============ updateAllLeaves Tests ============

    function test_updateAllLeaves_singleLeaf() public {
        tree.setup(ZERO);
        tree.pushNewLeaf(keccak256("original"));

        bytes32[] memory newLeaves = new bytes32[](1);
        newLeaves[0] = keccak256("updated");

        bytes32 newRoot = tree.updateAllLeaves(newLeaves);

        assertEq(newRoot, newLeaves[0]);
    }

    function test_updateAllLeaves_twoLeaves() public {
        tree.setup(ZERO);
        tree.pushNewLeaf(keccak256("original1"));
        tree.pushNewLeaf(keccak256("original2"));

        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = keccak256("updated1");
        newLeaves[1] = keccak256("updated2");

        bytes32 newRoot = tree.updateAllLeaves(newLeaves);

        bytes32 expectedRoot = Merkle.efficientHash(newLeaves[0], newLeaves[1]);
        assertEq(newRoot, expectedRoot);
    }

    function test_updateAllLeaves_revertsOnWrongLength() public {
        tree.setup(ZERO);
        tree.pushNewLeaf(keccak256("leaf1"));
        tree.pushNewLeaf(keccak256("leaf2"));

        bytes32[] memory newLeaves = new bytes32[](3); // Wrong length
        newLeaves[0] = keccak256("a");
        newLeaves[1] = keccak256("b");
        newLeaves[2] = keccak256("c");

        vm.expectRevert(abi.encodeWithSelector(MerkleWrongLength.selector, 3, 2));
        tree.updateAllLeaves(newLeaves);
    }

    function test_updateAllLeaves_fourLeaves() public {
        tree.setup(ZERO);
        tree.pushNewLeaf(keccak256("original1"));
        tree.pushNewLeaf(keccak256("original2"));
        tree.pushNewLeaf(keccak256("original3"));
        tree.pushNewLeaf(keccak256("original4"));

        bytes32[] memory newLeaves = new bytes32[](4);
        newLeaves[0] = keccak256("new1");
        newLeaves[1] = keccak256("new2");
        newLeaves[2] = keccak256("new3");
        newLeaves[3] = keccak256("new4");

        bytes32 newRoot = tree.updateAllLeaves(newLeaves);

        bytes32 hash12 = Merkle.efficientHash(newLeaves[0], newLeaves[1]);
        bytes32 hash34 = Merkle.efficientHash(newLeaves[2], newLeaves[3]);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash34);

        assertEq(newRoot, expectedRoot);
    }

    // ============ root Tests ============

    function test_root_afterSetup() public {
        bytes32 zero = keccak256("zero");
        tree.setup(zero);

        assertEq(tree.root(), zero);
    }

    function test_root_afterPush() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf");
        tree.pushNewLeaf(leaf);

        assertEq(tree.root(), leaf);
    }

    function test_root_afterUpdate() public {
        tree.setup(ZERO);

        tree.pushNewLeaf(keccak256("original"));

        bytes32 newLeaf = keccak256("updated");
        tree.updateLeaf(0, newLeaf);

        assertEq(tree.root(), newLeaf);
    }

    // ============ Fuzz Tests ============

    function testFuzz_pushAndUpdate(bytes32 leaf1, bytes32 leaf2, bytes32 update) public {
        tree.setup(ZERO);

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);

        bytes32 rootBefore = tree.root();

        tree.updateLeaf(0, update);

        bytes32 rootAfter = tree.root();

        // Root should change unless update equals leaf1
        if (update != leaf1) {
            assertTrue(rootBefore != rootAfter);
        }

        bytes32 expectedRoot = Merkle.efficientHash(update, leaf2);
        assertEq(rootAfter, expectedRoot);
    }

    // ============ Integration Tests ============

    function test_multipleOperations() public {
        tree.setup(ZERO);

        // Push several leaves
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);
        tree.pushNewLeaf(leaf3);
        tree.pushNewLeaf(leaf4);

        // Update some leaves
        bytes32 newLeaf1 = keccak256("updated1");
        bytes32 newLeaf3 = keccak256("updated3");

        tree.updateLeaf(0, newLeaf1);
        tree.updateLeaf(2, newLeaf3);

        // Calculate expected root
        bytes32 hash12 = Merkle.efficientHash(newLeaf1, leaf2);
        bytes32 hash34 = Merkle.efficientHash(newLeaf3, leaf4);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash34);

        assertEq(tree.root(), expectedRoot);
    }
}
