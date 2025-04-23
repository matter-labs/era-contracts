// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";
import {MerkleWrongIndex} from "contracts/common/L1ContractErrors.sol";

contract UpdateLeafTest is FullMerkleTest {
    function test_revertWhen_wrongIndex() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Preparing new leaf 1
        bytes32 newLeaf1 = keccak256("New Leaf 1");

        // Updating leaf 1 with wrong index
        vm.expectRevert(abi.encodeWithSelector(MerkleWrongIndex.selector, 2, 1));
        merkleTest.updateLeaf(2, newLeaf1);
    }

    function test_updateLeaf() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Updating leaf 1
        bytes32 newLeaf1 = keccak256("New Leaf 1");
        merkleTest.updateLeaf(1, newLeaf1);

        // Checking leaf nodes
        assertEq(merkleTest.node(0, 0), leaf0, "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), newLeaf1, "Node 0,1 should be correctly inserted");

        // Checking parent node
        bytes32 l01Hashed = keccak(leaf0, newLeaf1);
        assertEq(merkleTest.node(1, 0), l01Hashed, "Node 1,0 should be correctly inserted");
    }
}
