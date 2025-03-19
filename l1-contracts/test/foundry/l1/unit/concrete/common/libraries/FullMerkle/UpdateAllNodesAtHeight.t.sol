// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";

contract UpdateAllNodesAtHeightTest is FullMerkleTest {
    function test_height0() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");

        // Updating all nodes at height 0
        merkleTest.updateAllNodesAtHeight(0, newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), newLeaves[0], "Node 0,0 should be correctly updated");
        assertEq(merkleTest.node(0, 1), newLeaves[1], "Node 0,1 should be correctly updated");

        // Checking parent node
        bytes32 l01Hashed = keccak(newLeaves[0], newLeaves[1]);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly updated");
    }

    function test_height1() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);
        merkleTest.pushNewLeaf(leaf2);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");

        // Updating all nodes at height 1
        merkleTest.updateAllNodesAtHeight(1, newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), leaf1, "Node 0,1 should be correctly inserted");
        assertEq(merkleTest.node(0, 2), leaf2, "Node 0,2 should be correctly inserted");

        // Checking parent nodes
        assertEq(merkleTest.node(1, 0), newLeaves[0], "Node 1,0 should be correctly updated");
        assertEq(merkleTest.node(1, 1), newLeaves[1], "Node 1,1 should be correctly updated");
    }

    function test_height2() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);
        merkleTest.pushNewLeaf(leaf2);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](1);
        newLeaves[0] = keccak256("New Leaf 0");

        // Updating all nodes at height 2
        merkleTest.updateAllNodesAtHeight(2, newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), leaf1, "Node 0,1 should be correctly inserted");

        // Checking parent node
        assertEq(merkleTest.node(1, 0), keccak(leaf0, leaf1), "Node 1,0 should be correctly inserted");
        assertEq(merkleTest.node(2, 0), newLeaves[0], "Node 2,0 should be correctly updated");
    }
}
