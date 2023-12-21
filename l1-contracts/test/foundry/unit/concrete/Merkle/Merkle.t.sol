// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleTest} from "solpp/dev-contracts/test/MerkleTest.sol";
import {MerkleTreeNoSort} from "./MerkleTreeNoSort.sol";

contract MerkleTestTest is Test {
    MerkleTreeNoSort merkleTree;
    MerkleTest merkleTest;
    bytes32[] elements;
    bytes32 root;

    function setUp() public {
        merkleTree = new MerkleTreeNoSort();
        merkleTest = new MerkleTest();

        elements.push(keccak256(hex"41"));
        elements.push(keccak256(hex"42"));
        elements.push(keccak256(hex"43"));
        elements.push(keccak256(hex"44"));
        elements.push(keccak256(hex"45"));
        elements.push(keccak256(hex"46"));
        elements.push(keccak256(hex"47"));
        elements.push(keccak256(hex"48"));
        elements.push(keccak256(hex"49"));
        elements.push(keccak256(hex"4a"));
        elements.push(keccak256(hex"4b"));
        elements.push(keccak256(hex"4c"));
        elements.push(keccak256(hex"4d"));
        elements.push(keccak256(hex"4e"));
        elements.push(keccak256(hex"4f"));
        elements.push(keccak256(hex"50"));
        elements.push(keccak256(hex"51"));
        elements.push(keccak256(hex"52"));
        elements.push(keccak256(hex"53"));
        elements.push(keccak256(hex"54"));
        elements.push(keccak256(hex"55"));
        elements.push(keccak256(hex"56"));
        elements.push(keccak256(hex"57"));
        elements.push(keccak256(hex"58"));
        elements.push(keccak256(hex"59"));
        elements.push(keccak256(hex"5a"));
        elements.push(keccak256(hex"61"));
        elements.push(keccak256(hex"62"));
        elements.push(keccak256(hex"63"));
        elements.push(keccak256(hex"64"));
        elements.push(keccak256(hex"65"));
        elements.push(keccak256(hex"66"));
        elements.push(keccak256(hex"67"));
        elements.push(keccak256(hex"68"));
        elements.push(keccak256(hex"69"));
        elements.push(keccak256(hex"6a"));
        elements.push(keccak256(hex"6b"));
        elements.push(keccak256(hex"6c"));
        elements.push(keccak256(hex"6d"));
        elements.push(keccak256(hex"6e"));
        elements.push(keccak256(hex"6f"));
        elements.push(keccak256(hex"70"));
        elements.push(keccak256(hex"71"));
        elements.push(keccak256(hex"72"));
        elements.push(keccak256(hex"73"));
        elements.push(keccak256(hex"74"));
        elements.push(keccak256(hex"75"));
        elements.push(keccak256(hex"76"));
        elements.push(keccak256(hex"77"));
        elements.push(keccak256(hex"78"));
        elements.push(keccak256(hex"79"));
        elements.push(keccak256(hex"7a"));
        elements.push(keccak256(hex"30"));
        elements.push(keccak256(hex"31"));
        elements.push(keccak256(hex"32"));
        elements.push(keccak256(hex"33"));
        elements.push(keccak256(hex"34"));
        elements.push(keccak256(hex"35"));
        elements.push(keccak256(hex"36"));
        elements.push(keccak256(hex"37"));
        elements.push(keccak256(hex"38"));
        elements.push(keccak256(hex"39"));
        elements.push(keccak256(hex"2b"));
        elements.push(keccak256(hex"2f"));

        root = merkleTree.getRoot(elements);
    }

    function testElements(uint256 i) public {
        vm.assume(i < elements.length);
        bytes32 leaf = elements[i];
        bytes32[] memory proof = merkleTree.getProof(elements, i);

        bytes32 rootFromContract = merkleTest.calculateRoot(proof, i, leaf);

        assertEq(rootFromContract, root);
    }

    function testEmptyProof_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof;

        vm.expectRevert(bytes("xc"));
        merkleTest.calculateRoot(proof, 0, leaf);
    }

    function testLeafIndexTooBig_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        vm.expectRevert(bytes("px"));
        merkleTest.calculateRoot(proof, 2 ** 255, leaf);
    }

    function testProofLengthTooLarge_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = new bytes32[](256);

        vm.expectRevert(bytes("bt"));
        merkleTest.calculateRoot(proof, 0, leaf);
    }
}
