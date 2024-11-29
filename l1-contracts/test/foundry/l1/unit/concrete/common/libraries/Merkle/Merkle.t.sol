// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {MerkleTreeNoSort} from "./MerkleTreeNoSort.sol";
import {MerklePathEmpty, MerkleIndexOutOfBounds, MerklePathOutOfBounds, MerklePathLengthMismatch, MerkleIndexOrHeightMismatch, MerkleNothingToProve} from "contracts/common/L1ContractErrors.sol";

contract MerkleTestTest is Test {
    MerkleTreeNoSort merkleTree;
    MerkleTreeNoSort smallMerkleTree;
    MerkleTest merkleTest;
    bytes32[] elements;
    bytes32 root;

    function setUp() public {
        merkleTree = new MerkleTreeNoSort();
        smallMerkleTree = new MerkleTreeNoSort();
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

    function prepareRangeProof(
        uint256 start,
        uint256 end
    ) public returns (bytes32[] memory, bytes32[] memory, bytes32[] memory) {
        bytes32[] memory left = merkleTree.getProof(elements, start);
        bytes32[] memory right = merkleTree.getProof(elements, end);
        bytes32[] memory leaves = new bytes32[](end - start + 1);
        for (uint256 i = start; i <= end; ++i) {
            leaves[i - start] = elements[i];
        }

        return (left, right, leaves);
    }

    function testFirstElement() public {
        testElements(0);
    }

    function testLastElement() public {
        testElements(elements.length - 1);
    }

    function testEmptyProof_shouldSucceed() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof;

        bytes32 root = merkleTest.calculateRoot(proof, 0, leaf);
        assertEq(root, leaf);
    }

    function testLeafIndexTooBig_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        vm.expectRevert(MerkleIndexOutOfBounds.selector);
        merkleTest.calculateRoot(proof, 2 ** 255, leaf);
    }

    function testProofLengthTooLarge_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = new bytes32[](256);

        vm.expectRevert(MerklePathOutOfBounds.selector);
        merkleTest.calculateRoot(proof, 0, leaf);
    }

    function testRangeProof() public {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 10, leaves);
        assertEq(rootFromContract, root);
    }

    function testRangeProofIncorrect() public {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 9, leaves);
        assertNotEq(rootFromContract, root);
    }

    function testRangeProofLengthMismatch_shouldRevert() public {
        (, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        bytes32[] memory leftShortened = new bytes32[](right.length - 1);

        vm.expectRevert(abi.encodeWithSelector(MerklePathLengthMismatch.selector, 6, 7));
        merkleTest.calculateRoot(leftShortened, right, 10, leaves);
    }

    function testRangeProofEmptyPaths_shouldRevert() public {
        (, , bytes32[] memory leaves) = prepareRangeProof(10, 13);
        bytes32[] memory left;
        bytes32[] memory right;

        vm.expectRevert(MerklePathEmpty.selector);
        merkleTest.calculateRoot(left, right, 10, leaves);
    }

    function testRangeProofWrongIndex_shouldRevert() public {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        vm.expectRevert(MerkleIndexOrHeightMismatch.selector);
        merkleTest.calculateRoot(left, right, 128, leaves);
    }

    function testRangeProofSingleLeaf() public {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 10);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 10, leaves);
        assertEq(rootFromContract, root);
    }

    function testRangeProofEmpty_shouldRevert() public {
        bytes32[] memory left = merkleTree.getProof(elements, 10);
        bytes32[] memory right = merkleTree.getProof(elements, 10);
        bytes32[] memory leaves;
        vm.expectRevert(MerkleNothingToProve.selector);
        merkleTest.calculateRoot(left, right, 10, leaves);
    }

    function testRangeProofSingleElementTree() public {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = elements[10];
        bytes32[] memory left = new bytes32[](0);
        bytes32[] memory right = new bytes32[](0);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 0, leaves);
        assertEq(rootFromContract, leaves[0]);
    }
}
