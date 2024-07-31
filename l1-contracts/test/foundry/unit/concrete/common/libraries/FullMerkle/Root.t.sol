// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";

contract RootTest is FullMerkleTest {
    function test_emptyTree() public view {
        // Initially tree is empty, root is the zero hash
        assertEq(merkleTest.root(), zeroHash, "Root should be zero hash initially");
    }

    function test_oneLeaf() public {
        // Inserting one leaf
        bytes32 leaf = keccak256("Leaf 0");
        merkleTest.pushNewLeaf(leaf);

        // With one leaf, root is the leaf itself
        assertEq(merkleTest.root(), leaf, "Root should be the leaf hash");
    }

    function test_twoLeaves() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Calculate expected root
        bytes32 expectedRoot = keccak(leaf0, leaf1);
        assertEq(merkleTest.root(), expectedRoot, "Root should be the hash of the two leaves");
    }

    function test_nodeCountAndRoot() public {
        // Initially tree is empty
        assertEq(merkleTest.nodeCount(0), 1, "Initial node count at height 0 should be 1");

        // Inserting three leaves and checking counts and root
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);
        merkleTest.pushNewLeaf(leaf2);

        assertEq(merkleTest.nodeCount(0), 3, "Node count at height 0 should be 3 after three inserts");
        assertEq(merkleTest.nodeCount(1), 2, "Node count at height 1 should be 2");
        assertEq(merkleTest.nodeCount(2), 1, "Node count at height 2 should be 1");

        // Calculate expected root to verify correctness
        bytes32 leftChild = keccak(leaf0, leaf1);
        bytes32 rightChild = keccak(leaf2, merkleTest.zeros(0));
        bytes32 expectedRoot = keccak(leftChild, rightChild);

        assertEq(merkleTest.root(), expectedRoot, "Root should match expected value after inserts");
    }
}
