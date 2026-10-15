// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MerkleWrongIndex} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for FullMerkle library
contract FullMerkleLibraryTest is Test {
    using FullMerkle for FullMerkle.FullTree;

    FullMerkle.FullTree internal tree;

    bytes32 internal constant ZERO = keccak256("ZERO");

    // ============ setup Tests ============

    function test_setup_initializesTree() public {
        bytes32 initialRoot = tree.setup(ZERO);

        assertEq(initialRoot, ZERO);
        assertEq(tree.root(), ZERO);
        assertEq(tree._height, 0);
        assertEq(tree._leafNumber, 0);
        assertEq(tree._zeros[0], ZERO);
    }

    // ============ pushNewLeaf Tests ============

    function test_pushNewLeaf_firstLeaf() public {
        tree.setup(ZERO);

        bytes32 leaf = keccak256("leaf1");
        bytes32 newRoot = tree.pushNewLeaf(leaf);

        assertEq(newRoot, leaf);
        assertEq(tree.root(), leaf);
        assertEq(tree._height, 0);
        assertEq(tree._leafNumber, 1);
        assertEq(tree._nodes[0][0], leaf);
    }

    function test_pushNewLeaf_twoLeaves() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        tree.pushNewLeaf(leaf1);
        bytes32 newRoot = tree.pushNewLeaf(leaf2);

        bytes32 expectedRoot = Merkle.efficientHash(leaf1, leaf2);
        assertEq(newRoot, expectedRoot);
        assertEq(tree._height, 1);
        assertEq(tree._leafNumber, 2);
        assertEq(tree._nodes[0][0], leaf1);
        assertEq(tree._nodes[0][1], leaf2);
        assertEq(tree._nodes[1][0], expectedRoot);
        assertEq(tree._zeros[1], Merkle.efficientHash(ZERO, ZERO));
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
        assertEq(tree._height, 2);
        assertEq(tree._leafNumber, 3);
        assertEq(tree._nodes[0].length, 3);
        assertEq(tree._nodes[1].length, 2);
        assertEq(tree._nodes[2].length, 1);
        assertEq(tree._nodes[0][2], leaf3);
        assertEq(tree._nodes[1][0], hash12);
        assertEq(tree._nodes[1][1], hash3Zero);
        assertEq(tree._nodes[2][0], expectedRoot);
        bytes32 zero1 = Merkle.efficientHash(ZERO, ZERO);
        assertEq(tree._zeros[1], zero1);
        assertEq(tree._zeros[2], Merkle.efficientHash(zero1, zero1));
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
        assertEq(tree._nodes[0][0], leaf1);
        assertEq(tree._nodes[0][1], newLeaf);
        assertEq(tree._nodes[1][0], expectedRoot);
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

    // ============ merklePath Tests ============

    function test_merklePath_revertsOnInvalidIndex() public {
        tree.setup(ZERO);
        tree.pushNewLeaf(keccak256("leaf1"));
        tree.pushNewLeaf(keccak256("leaf2"));

        vm.expectRevert(abi.encodeWithSelector(MerkleWrongIndex.selector, 2, 1));
        tree.merklePath(2);
    }

    function test_merklePath() public {
        tree.setup(ZERO);
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");
        tree.pushNewLeaf(leaf0);
        tree.pushNewLeaf(leaf1);

        bytes32[] memory expectedProof = new bytes32[](1);
        expectedProof[0] = leaf1;
        assertEq(tree.merklePath(0), expectedProof, "Incorrect proof for leaf #0 in tree with 2 leaves");
        expectedProof[0] = leaf0;
        assertEq(tree.merklePath(1), expectedProof, "Incorrect proof for leaf #1 in tree with 2 leaves");

        bytes32 leaf2 = keccak256("leaf2");
        tree.pushNewLeaf(leaf2);
        bytes32 node10 = Merkle.efficientHash(leaf0, leaf1);
        bytes32 node11 = Merkle.efficientHash(leaf2, ZERO);

        expectedProof = new bytes32[](2);
        expectedProof[0] = leaf1;
        expectedProof[1] = node11;
        assertEq(tree.merklePath(0), expectedProof, "Incorrect proof for leaf #0 in tree with 3 leaves");

        expectedProof[0] = leaf0;
        assertEq(tree.merklePath(1), expectedProof, "Incorrect proof for leaf #1 in tree with 3 leaves");

        expectedProof[0] = ZERO;
        expectedProof[1] = node10;
        assertEq(tree.merklePath(2), expectedProof, "Incorrect proof for leaf #2 in tree with 3 leaves");
    }

    // ============ Fuzz Tests ============

    function testFuzz_pushAndUpdate(bytes32 _leaf1, bytes32 _leaf2, bytes32 _update) public {
        tree.setup(ZERO);

        tree.pushNewLeaf(_leaf1);
        tree.pushNewLeaf(_leaf2);

        bytes32 rootBefore = tree.root();

        tree.updateLeaf(0, _update);

        bytes32 rootAfter = tree.root();

        if (_update != _leaf1) {
            assertTrue(rootBefore != rootAfter);
        }

        bytes32 expectedRoot = Merkle.efficientHash(_update, _leaf2);
        assertEq(rootAfter, expectedRoot);
    }

    // ============ Integration Tests ============

    function test_multipleOperations() public {
        tree.setup(ZERO);

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        tree.pushNewLeaf(leaf1);
        tree.pushNewLeaf(leaf2);
        tree.pushNewLeaf(leaf3);
        tree.pushNewLeaf(leaf4);

        bytes32 newLeaf1 = keccak256("updated1");
        bytes32 newLeaf3 = keccak256("updated3");

        tree.updateLeaf(0, newLeaf1);
        tree.updateLeaf(2, newLeaf3);

        bytes32 hash12 = Merkle.efficientHash(newLeaf1, leaf2);
        bytes32 hash34 = Merkle.efficientHash(newLeaf3, leaf4);
        bytes32 expectedRoot = Merkle.efficientHash(hash12, hash34);

        assertEq(tree.root(), expectedRoot);
    }
}
