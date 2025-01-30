// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";
import {MerkleWrongLength} from "contracts/common/L1ContractErrors.sol";

contract UpdateAllLeavesTest is FullMerkleTest {
    function test_revertWhen_wrongLength() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](3);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");
        newLeaves[2] = keccak256("New Leaf 2");

        // Updating all leaves with wrong length
        vm.expectRevert(abi.encodeWithSelector(MerkleWrongLength.selector, newLeaves.length, 2));
        merkleTest.updateAllLeaves(newLeaves);
    }

    function test_oneLeaf() public {
        // Inserting one leaf
        bytes32 leaf0 = keccak256("Leaf 0");
        merkleTest.pushNewLeaf(leaf0);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](1);
        newLeaves[0] = keccak256("New Leaf 0");

        // Updating all leaves
        merkleTest.updateAllLeaves(newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), newLeaves[0], "Node 0,0 should be correctly updated");
    }

    function test_twoLeaves() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");

        // Updating all leaves
        merkleTest.updateAllLeaves(newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), newLeaves[0], "Node 0,0 should be correctly updated");
        assertEq(merkleTest.node(0, 1), newLeaves[1], "Node 0,1 should be correctly updated");

        // Checking parent node
        bytes32 l01Hashed = keccak(newLeaves[0], newLeaves[1]);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly updated");
    }

    function test_threeLeaves() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);
        merkleTest.pushNewLeaf(leaf2);

        // Preparing new leaves for full update
        bytes32[] memory newLeaves = new bytes32[](3);
        newLeaves[0] = keccak256("New Leaf 0");
        newLeaves[1] = keccak256("New Leaf 1");
        newLeaves[2] = keccak256("New Leaf 2");

        // Updating all leaves
        merkleTest.updateAllLeaves(newLeaves);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), newLeaves[0], "Node 0,0 should be correctly updated");
        assertEq(merkleTest.node(0, 1), newLeaves[1], "Node 0,1 should be correctly updated");
        assertEq(merkleTest.node(0, 2), newLeaves[2], "Node 0,2 should be correctly updated");

        // Checking parent nodes
        bytes32 l01Hashed = keccak(newLeaves[0], newLeaves[1]);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly updated");
        // There is no leaf3 so we hash leaf2 with zero
        bytes32 l23Hashed = keccak(newLeaves[2], merkleTest.zeros(0));
        assertEq(merkleTest.node(1, 1), l23Hashed, "Node 1,1 should be correctly updated");

        // Checking root node
        bytes32 l01l23Hashed = keccak(l01Hashed, l23Hashed);
        assertEq(merkleTest.node(2, 0), l01l23Hashed, "Node 2,0 should be correctly updated");
    }
}
