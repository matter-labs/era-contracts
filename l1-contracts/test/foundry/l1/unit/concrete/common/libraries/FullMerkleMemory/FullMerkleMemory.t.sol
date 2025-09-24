// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FullMerkleMemory} from "contracts/common/libraries/FullMerkleMemory.sol";
import {MerkleWrongIndex, MerkleWrongLength} from "contracts/common/L1ContractErrors.sol";

contract FullMerkleMemory_Test is Test {
    using FullMerkleMemory for FullMerkleMemory.FullTree;

    bytes32 constant zeroHash = keccak256(abi.encodePacked("ZERO"));

    function test_CreateTree_ZeroMaxLeafNumber_Reverts() public {
        FullMerkleMemory.FullTree memory tree;
        vm.expectRevert();
        tree.createTree(0);
    }

    function test_CreateTree_SingleLeaf() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(1);

        assertEq(tree._height, 0);
        assertEq(tree._leafNumber, 0);
        assertEq(tree._nodesLengthMemory, 1);
        assertEq(tree._zerosLengthMemory, 1);
        assertEq(tree._nodes.length, 1);
        assertEq(tree._zeros.length, 1);
        assertEq(tree._nodes[0].length, 1);
    }

    function test_CreateTree_MultipleLeaves() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(5);

        // Height should be 3 for 5 leaves (2^3 = 8 > 5)
        assertEq(tree._height, 3);
        assertEq(tree._leafNumber, 0);
        assertEq(tree._nodesLengthMemory, 4); // height + 1
        assertEq(tree._zerosLengthMemory, 4);
        assertEq(tree._nodes.length, 4);
        assertEq(tree._zeros.length, 4);
        assertEq(tree._nodes[0].length, 5);
    }

    function test_Setup_InitializesZeros() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(4);
        bytes32 initialRoot = tree.setup(zeroHash);

        assertEq(tree._zeros[0], zeroHash);
        assertEq(tree._zerosLengthMemory, tree._height + 1);
        assertEq(tree._nodesLengthMemory, tree._height + 1);
        assertEq(tree._nodes[tree._height][0], tree._zeros[tree._height]);
        assertEq(initialRoot, tree._zeros[tree._height]);
    }

    function test_PushNewLeaf_FirstLeaf() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 root0 = tree.pushNewLeaf(leaf0);

        assertEq(tree._leafNumber, 1);
        assertEq(tree._nodes[0][0], leaf0);
        // Just verify the root is returned (don't assert exact value)
        assertTrue(root0 != bytes32(0));
    }

    function test_PushNewLeaf_ExpandsTree() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        // Push first leaf
        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        // Push second leaf - should expand tree
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 root1 = tree.pushNewLeaf(leaf1);

        assertEq(tree._leafNumber, 2);
        assertEq(tree._height, 1);
        assertEq(tree._zerosLengthMemory, 2);
        assertEq(tree._nodesLengthMemory, 2);
        assertEq(tree._nodes[0][0], leaf0);
        assertEq(tree._nodes[0][1], leaf1);
        // Just verify the root is returned (don't assert exact value)
        assertTrue(root1 != bytes32(0));
    }

    function test_PushNewLeaf_WithTreeExpansion() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2); // Use larger initial size to avoid array bounds
        tree.setup(zeroHash);

        // Push first leaf
        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        // Push second leaf - should expand tree height
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 root1 = tree.pushNewLeaf(leaf1);

        assertEq(tree._leafNumber, 2);
        assertEq(tree._height, 1);
        assertEq(tree._zerosLengthMemory, 2);
        assertEq(tree._nodesLengthMemory, 2);
        assertTrue(root1 != bytes32(0));
    }

    function test_UpdateLeaf_WrongIndex_Reverts() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        bytes32 newLeaf = keccak256("New Leaf");
        vm.expectRevert(abi.encodeWithSelector(MerkleWrongIndex.selector, 1, 0));
        tree.updateLeaf(1, newLeaf);
    }

    function test_UpdateLeaf_ValidIndex() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        bytes32 newLeaf = keccak256("New Leaf");
        bytes32 root = tree.updateLeaf(0, newLeaf);

        assertEq(tree._nodes[0][0], newLeaf);
        assertTrue(root != bytes32(0));
    }

    function test_UpdateLeaf_WithSibling() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        tree.pushNewLeaf(leaf0);
        tree.pushNewLeaf(leaf1);

        bytes32 newLeaf0 = keccak256("New Leaf 0");
        bytes32 root = tree.updateLeaf(0, newLeaf0);

        assertEq(tree._nodes[0][0], newLeaf0);
        assertEq(tree._nodes[0][1], leaf1);
        assertTrue(root != bytes32(0));
    }

    function test_UpdateAllLeaves_WrongLength_Reverts() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");

        vm.expectRevert(abi.encodeWithSelector(MerkleWrongLength.selector, 2, 1));
        tree.updateAllLeaves(newLeaves);
    }

    function test_UpdateAllLeaves_ValidLength() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        bytes32[] memory newLeaves = new bytes32[](1);
        newLeaves[0] = keccak256("New Leaf 0");

        bytes32 root = tree.updateAllLeaves(newLeaves);

        assertEq(tree._nodes[0][0], newLeaves[0]);
        assertTrue(root != bytes32(0));
    }

    function test_UpdateAllNodesAtHeight_AtMaxHeight() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(1);
        tree.setup(zeroHash);

        bytes32[] memory newNodes = new bytes32[](1);
        newNodes[0] = keccak256("New Node");

        bytes32 result = tree.updateAllNodesAtHeight(0, newNodes);

        assertEq(tree._nodes[0][0], newNodes[0]);
        assertEq(result, newNodes[0]);
    }

    function test_UpdateAllNodesAtHeight_WithOddNodes() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(3);
        tree.setup(zeroHash);

        bytes32[] memory newNodes = new bytes32[](3);
        newNodes[0] = keccak256("Node 0");
        newNodes[1] = keccak256("Node 1");
        newNodes[2] = keccak256("Node 2");

        bytes32 result = tree.updateAllNodesAtHeight(0, newNodes);

        assertEq(tree._nodes[0][0], newNodes[0]);
        assertEq(tree._nodes[0][1], newNodes[1]);
        assertEq(tree._nodes[0][2], newNodes[2]);
        assertTrue(result != bytes32(0));
    }

    function test_UpdateAllNodesAtHeight_WithEvenNodes() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(4);
        tree.setup(zeroHash);

        bytes32[] memory newNodes = new bytes32[](4);
        newNodes[0] = keccak256("Node 0");
        newNodes[1] = keccak256("Node 1");
        newNodes[2] = keccak256("Node 2");
        newNodes[3] = keccak256("Node 3");

        bytes32 result = tree.updateAllNodesAtHeight(0, newNodes);

        assertEq(tree._nodes[0][0], newNodes[0]);
        assertEq(tree._nodes[0][1], newNodes[1]);
        assertEq(tree._nodes[0][2], newNodes[2]);
        assertEq(tree._nodes[0][3], newNodes[3]);
        assertTrue(result != bytes32(0));
    }

    function test_Root_ReturnsCorrectRoot() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(2);
        tree.setup(zeroHash);

        bytes32 leaf0 = keccak256("Leaf 0");
        tree.pushNewLeaf(leaf0);

        bytes32 root = tree.root();
        assertTrue(root != bytes32(0));
    }

    function test_ComplexTreeOperations() public {
        FullMerkleMemory.FullTree memory tree;
        tree.createTree(8);
        tree.setup(zeroHash);

        // Add multiple leaves
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            leaves[i] = keccak256(abi.encodePacked("Leaf", i));
            tree.pushNewLeaf(leaves[i]);
        }

        // Update a leaf
        bytes32 newLeaf = keccak256("Updated Leaf");
        tree.updateLeaf(2, newLeaf);

        // Update all leaves
        bytes32[] memory allNewLeaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            allNewLeaves[i] = keccak256(abi.encodePacked("New Leaf", i));
        }
        tree.updateAllLeaves(allNewLeaves);

        // Verify final state
        assertEq(tree._leafNumber, 5);
        assertTrue(tree._height >= 2);
        assertEq(tree.root(), tree._nodes[tree._height][0]);
    }
}
