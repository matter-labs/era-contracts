// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";

contract MerklePathTest is FullMerkleTest {
    function test_revertWhen_wrongIndex() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Check that getting merkle path for leaf with index 2 reverts.
        vm.expectRevert(bytes("FMT, wrong index"));
        merkleTest.merklePath(2);
    }

    function test_merklePath() public {
        // Inserting two leaves
        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        merkleTest.pushNewLeaf(leaf0);
        merkleTest.pushNewLeaf(leaf1);

        // Check proof for both leaves
        bytes32[] memory expectedProof = new bytes32[](1);

        bytes32[] memory proofFor0 = merkleTest.merklePath(0);
        expectedProof[0] = leaf1;
        assertEq(proofFor0, expectedProof, "Incorrect proof for leaf #0 in tree with 2 leaves");

        bytes32[] memory proofFor1 = merkleTest.merklePath(1);
        expectedProof[0] = leaf0;
        assertEq(proofFor1, expectedProof, "Incorrect proof for leaf #1 in tree with 2 leaves");

        // Add one more leaf
        bytes32 leaf2 = keccak256("Leaf 2");
        merkleTest.pushNewLeaf(leaf2);

        // Check proofs again
        bytes32 node10 = keccak(leaf0, leaf1);
        bytes32 node11 = keccak(leaf2, zeroHash);

        proofFor0 = merkleTest.merklePath(0);
        expectedProof = new bytes32[](2);
        expectedProof[0] = leaf1;
        expectedProof[1] = node11;
        assertEq(proofFor0, expectedProof, "Incorrect proof for leaf #0 in tree with 3 leaves");

        proofFor1 = merkleTest.merklePath(1);
        expectedProof[0] = leaf0;
        expectedProof[1] = node11;
        assertEq(proofFor1, expectedProof, "Incorrect proof for leaf #1 in tree with 3 leaves");

        bytes32[] memory proofFor2 = merkleTest.merklePath(2);
        expectedProof[0] = zeroHash;
        expectedProof[1] = node10;
        assertEq(proofFor2, expectedProof, "Incorrect proof for leaf #2 in tree with 3 leaves");
    }
}
