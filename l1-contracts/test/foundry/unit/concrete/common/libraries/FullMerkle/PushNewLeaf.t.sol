// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";

contract PushNewLeafTest is FullMerkleTest {
    function test_oneLeaf() public {
        // Inserting one leaf
        bytes32 leaf0 = keccak256("Leaf 0");
        merkleTest.pushNewLeaf(leaf0);

        // Checking the tree structure
        assertEq(merkleTest.height(), 0, "Height should be 0 after one insert");
        assertEq(merkleTest.index(), 1, "Leaf number should be 1 after one insert");

        // Checking leaf node
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");

        // Chekcking zeros tree structure
        assertEq(merkleTest.zeros(0), zeroHash, "Zero 0 should be correctly inserted");
    }

    function test_twoLeaves() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Checking the tree structure
        assertEq(merkleTest.height(), 1, "Height should be 1 after two inserts");
        assertEq(merkleTest.index(), 2, "Leaf number should be 2 after two inserts");

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), leaf1, "Node 0,1 should be correctly inserted");

        // Checking parent node
        bytes32 l01Hashed = keccak(leaf0, leaf1);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly inserted");

        // Checking zeros
        bytes32 zeroHashed = keccak(zeroHash, zeroHash);
        assertEq(merkleTest.zeros(1), zeroHashed, "Zero 1 should be correctly inserted");
    }

    function test_threeLeaves() public {
        // Insert three leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);
        merkleTest.pushNewLeaf(leaf2);

        // Checking the tree structure
        assertEq(merkleTest.height(), 2, "Height should be 2 after three inserts");
        assertEq(merkleTest.index(), 3, "Leaf number should be 3 after three inserts");

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), leaf1, "Node 0,1 should be correctly inserted");
        assertEq(merkleTest.node(0, 2), leaf2, "Node 0,2 should be correctly inserted");

        // Checking parent nodes
        bytes32 l01Hashed = keccak(leaf0, leaf1);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly inserted");
        // there is no leaf3 so we hash leaf2 with zero
        bytes32 l23Hashed = keccak(leaf2, merkleTest.zeros(0));
        assertEq(merkleTest.node(1, 1), l23Hashed, "Node 1,1 should be correctly inserted");

        // Checking root node
        bytes32 l01l23Hashed = keccak(l01Hashed, l23Hashed);
        assertEq(merkleTest.node(2, 0), l01l23Hashed, "Node 2,0 should be correctly inserted");

        // Checking zero
        bytes32 zeroHashed = keccak(zeroHash, zeroHash);
        assertEq(merkleTest.zeros(1), zeroHashed, "Zero 1 should be correctly inserted");
        bytes32 zhHashed = keccak(zeroHashed, zeroHashed);
        assertEq(merkleTest.zeros(2), zhHashed, "Zero 2 should be correctly inserted");
    }
}
