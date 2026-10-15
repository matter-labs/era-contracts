// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MerkleTreeNoSort} from "./MerkleTreeNoSort.sol";
import {
    MerkleIndexOrHeightMismatch,
    MerkleIndexOutOfBounds,
    MerkleNothingToProve,
    MerklePathEmpty,
    MerklePathLengthMismatch,
    MerklePathOutOfBounds
} from "contracts/common/L1ContractErrors.sol";

contract MerkleTestTest is Test {
    MerkleTreeNoSort internal merkleTree;
    MerkleTreeNoSort internal smallMerkleTree;
    MerkleTest internal merkleTest;
    bytes32[] internal elements;
    bytes32 internal root;

    function setUp() public {
        merkleTree = new MerkleTreeNoSort();
        smallMerkleTree = new MerkleTreeNoSort();
        merkleTest = new MerkleTest();

        for (uint256 i = 0; i < 65; i++) {
            elements.push(keccak256(abi.encodePacked(i)));
        }

        root = merkleTree.getRoot(elements);
    }

    function testElements(uint256 _i) public view {
        vm.assume(_i < elements.length);
        bytes32 leaf = elements[_i];
        bytes32[] memory proof = merkleTree.getProof(elements, _i);

        bytes32 rootFromContract = merkleTest.calculateRoot(proof, _i, leaf);

        assertEq(rootFromContract, root);
    }

    function prepareRangeProof(
        uint256 _start,
        uint256 _end
    ) public view returns (bytes32[] memory, bytes32[] memory, bytes32[] memory) {
        bytes32[] memory left = merkleTree.getProof(elements, _start);
        bytes32[] memory right = merkleTree.getProof(elements, _end);
        bytes32[] memory leaves = new bytes32[](_end - _start + 1);
        for (uint256 i = _start; i <= _end; ++i) {
            leaves[i - _start] = elements[i];
        }

        return (left, right, leaves);
    }

    function testFirstElement() public view {
        testElements(0);
    }

    function testLastElement() public view {
        testElements(elements.length - 1);
    }

    function testEmptyProof_shouldSucceed() public view {
        bytes32 leaf = elements[0];
        bytes32[] memory proof;

        bytes32 calculatedRoot = merkleTest.calculateRoot(proof, 0, leaf);
        assertEq(calculatedRoot, leaf);
    }

    function testLeafIndexTooBig_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        vm.expectRevert(MerkleIndexOutOfBounds.selector);
        merkleTest.calculateRoot(proof, 1 << proof.length, leaf);
    }

    function testProofLengthTooLarge_shouldRevert() public {
        bytes32 leaf = elements[0];
        bytes32[] memory proof = new bytes32[](256);

        vm.expectRevert(MerklePathOutOfBounds.selector);
        merkleTest.calculateRoot(proof, 0, leaf);
    }

    function testMaxPathLength_shouldSucceed() public view {
        bytes32 leaf = elements[0];
        bytes32[] memory path = new bytes32[](255);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;

        bytes32 expectedRoot = leaf;
        for (uint256 i = 0; i < path.length; ++i) {
            expectedRoot = Merkle.efficientHash(expectedRoot, bytes32(0));
        }
        assertEq(merkleTest.calculateRoot(path, 0, leaf), expectedRoot);
        assertEq(merkleTest.calculateRoot(path, path, 0, leaves), expectedRoot);
    }

    function testElementsMemory(uint256 _index) public view {
        _index = bound(_index, 0, elements.length - 1);
        bytes32[] memory proof = merkleTree.getProof(elements, _index);

        assertEq(Merkle.calculateRootMemory(proof, _index, elements[_index]), root);
    }

    function testEmptyProofMemory_shouldSucceed() public view {
        bytes32[] memory proof;

        assertEq(Merkle.calculateRootMemory(proof, 0, elements[0]), elements[0]);
    }

    function testEfficientHash(bytes32 _lhs, bytes32 _rhs) public pure {
        assertEq(Merkle.efficientHash(_lhs, _rhs), keccak256(abi.encodePacked(_lhs, _rhs)));
    }

    function testRangeProof() public view {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 10, leaves);
        assertEq(rootFromContract, root);
    }

    function testRangeProofIncorrect() public view {
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

        // Either condition alone must revert: several leaves at index 0, one leaf at a non-zero index.
        vm.expectRevert(MerklePathEmpty.selector);
        merkleTest.calculateRoot(left, right, 0, leaves);

        vm.expectRevert(MerklePathEmpty.selector);
        merkleTest.calculateRoot(left, right, 1, new bytes32[](1));
    }

    function testRangeProofPathTooLong_shouldRevert() public {
        bytes32[] memory left = new bytes32[](256);
        bytes32[] memory right = new bytes32[](256);
        bytes32[] memory leaves = new bytes32[](1);

        vm.expectRevert(MerklePathOutOfBounds.selector);
        merkleTest.calculateRoot(left, right, 0, leaves);
    }

    function testRangeProofWrongIndex_shouldRevert() public {
        (bytes32[] memory left, bytes32[] memory right, bytes32[] memory leaves) = prepareRangeProof(10, 13);
        vm.expectRevert(MerkleIndexOrHeightMismatch.selector);
        merkleTest.calculateRoot(left, right, 125, leaves);
    }

    function testRangeProofSingleLeaf() public view {
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

    function testRangeProofSingleElementTree() public view {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = elements[10];
        bytes32[] memory left = new bytes32[](0);
        bytes32[] memory right = new bytes32[](0);
        bytes32 rootFromContract = merkleTest.calculateRoot(left, right, 0, leaves);
        assertEq(rootFromContract, leaves[0]);
    }
}
