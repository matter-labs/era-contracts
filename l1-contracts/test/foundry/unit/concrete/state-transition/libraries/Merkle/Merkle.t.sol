// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {MerkleTreeNoSort} from "./MerkleTreeNoSort.sol";

contract MerkleTestTest is Test {
    MerkleTreeNoSort merkleTree;
    MerkleTest merkleTest;
    bytes32[] elements;
    bytes32 root;

    function setUp() public {
        merkleTree = new MerkleTreeNoSort();
        merkleTest = new MerkleTest();

        for (uint256 i = 0; i < 65; i++) {
            elements.push(keccak256(abi.encodePacked(i)));
        }

        root = merkleTree.getRoot(elements);
    }

    function testElements(uint256 i) public {
        vm.assume(i < elements.length);
        bytes32 leaf = elements[i];
        bytes32[] memory proof = merkleTree.getProof(elements, i);

        bytes32 rootFromContract = merkleTest.calculateRoot(proof, i, leaf);

        assertEq(rootFromContract, root);
    }

    function testFirstElement() public {
        testElements(0);
    }

    function testLastElement() public {
        testElements(elements.length - 1);
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
