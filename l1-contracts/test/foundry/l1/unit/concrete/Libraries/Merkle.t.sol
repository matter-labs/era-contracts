// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MerkleIndexOrHeightMismatch, MerkleIndexOutOfBounds, MerkleNothingToProve, MerklePathEmpty, MerklePathLengthMismatch, MerklePathOutOfBounds} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for Merkle library
contract MerkleTest is Test {
    // ============ calculateRoot Tests ============

    function test_calculateRoot_singleLeaf() public {
        bytes32[] memory path = new bytes32[](0);
        bytes32 leaf = keccak256("leaf");

        bytes32 root = this.externalCalculateRoot(path, 0, leaf);

        // With no path, root equals leaf
        assertEq(root, leaf);
    }

    function test_calculateRoot_twoLeaves_leftChild() public {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");

        bytes32[] memory path = new bytes32[](1);
        path[0] = leaf1;

        bytes32 root = this.externalCalculateRoot(path, 0, leaf0);
        bytes32 expectedRoot = Merkle.efficientHash(leaf0, leaf1);

        assertEq(root, expectedRoot);
    }

    function test_calculateRoot_twoLeaves_rightChild() public {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");

        bytes32[] memory path = new bytes32[](1);
        path[0] = leaf0;

        bytes32 root = this.externalCalculateRoot(path, 1, leaf1);
        bytes32 expectedRoot = Merkle.efficientHash(leaf0, leaf1);

        assertEq(root, expectedRoot);
    }

    function test_calculateRoot_fourLeaves() public {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");

        // Build the tree
        bytes32 hash01 = Merkle.efficientHash(leaf0, leaf1);
        bytes32 hash23 = Merkle.efficientHash(leaf2, leaf3);
        bytes32 expectedRoot = Merkle.efficientHash(hash01, hash23);

        // Prove leaf0 (index 0)
        bytes32[] memory path = new bytes32[](2);
        path[0] = leaf1; // sibling at level 0
        path[1] = hash23; // sibling at level 1

        bytes32 root = this.externalCalculateRoot(path, 0, leaf0);
        assertEq(root, expectedRoot);
    }

    function test_calculateRoot_fourLeaves_rightmostLeaf() public {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");

        bytes32 hash01 = Merkle.efficientHash(leaf0, leaf1);
        bytes32 hash23 = Merkle.efficientHash(leaf2, leaf3);
        bytes32 expectedRoot = Merkle.efficientHash(hash01, hash23);

        // Prove leaf3 (index 3)
        bytes32[] memory path = new bytes32[](2);
        path[0] = leaf2; // sibling at level 0
        path[1] = hash01; // sibling at level 1

        bytes32 root = this.externalCalculateRoot(path, 3, leaf3);
        assertEq(root, expectedRoot);
    }

    function test_calculateRoot_revertsOnIndexOutOfBounds() public {
        bytes32[] memory path = new bytes32[](2); // Supports indices 0-3 (2^2 = 4)
        path[0] = bytes32(0);
        path[1] = bytes32(0);

        vm.expectRevert(MerkleIndexOutOfBounds.selector);
        this.externalCalculateRoot(path, 4, keccak256("leaf")); // Index 4 is out of bounds
    }

    function test_calculateRoot_revertsOnPathTooLong() public {
        bytes32[] memory path = new bytes32[](256);

        vm.expectRevert(MerklePathOutOfBounds.selector);
        this.externalCalculateRoot(path, 0, keccak256("leaf"));
    }

    // ============ calculateRootMemory Tests ============

    function test_calculateRootMemory_singleLeaf() public pure {
        bytes32[] memory path = new bytes32[](0);
        bytes32 leaf = keccak256("leaf");

        bytes32 root = Merkle.calculateRootMemory(path, 0, leaf);

        assertEq(root, leaf);
    }

    function test_calculateRootMemory_twoLeaves() public pure {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");

        bytes32[] memory path = new bytes32[](1);
        path[0] = leaf1;

        bytes32 root = Merkle.calculateRootMemory(path, 0, leaf0);
        bytes32 expectedRoot = Merkle.efficientHash(leaf0, leaf1);

        assertEq(root, expectedRoot);
    }

    function test_calculateRootMemory_matchesCalculateRoot() public {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");

        bytes32 hash01 = Merkle.efficientHash(leaf0, leaf1);
        bytes32 hash23 = Merkle.efficientHash(leaf2, leaf3);

        bytes32[] memory path = new bytes32[](2);
        path[0] = leaf1;
        path[1] = hash23;

        bytes32 rootMemory = Merkle.calculateRootMemory(path, 0, leaf0);
        bytes32 rootCalldata = this.externalCalculateRoot(path, 0, leaf0);

        assertEq(rootMemory, rootCalldata);
    }

    // ============ calculateRootPaths Tests ============

    function test_calculateRootPaths_singleElement() public pure {
        bytes32[] memory startPath = new bytes32[](0);
        bytes32[] memory endPath = new bytes32[](0);
        bytes32[] memory itemHashes = new bytes32[](1);
        itemHashes[0] = keccak256("leaf");

        bytes32 root = Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);

        assertEq(root, itemHashes[0]);
    }

    function test_calculateRootPaths_twoElements() public pure {
        bytes32 leaf0 = keccak256("leaf0");
        bytes32 leaf1 = keccak256("leaf1");

        bytes32[] memory startPath = new bytes32[](1);
        bytes32[] memory endPath = new bytes32[](1);
        startPath[0] = bytes32(0); // Not used since we have both leaves
        endPath[0] = bytes32(0); // Not used since we have both leaves

        bytes32[] memory itemHashes = new bytes32[](2);
        itemHashes[0] = leaf0;
        itemHashes[1] = leaf1;

        bytes32 root = Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
        bytes32 expectedRoot = Merkle.efficientHash(leaf0, leaf1);

        assertEq(root, expectedRoot);
    }

    function test_calculateRootPaths_revertsOnPathLengthMismatch() public {
        bytes32[] memory startPath = new bytes32[](2);
        bytes32[] memory endPath = new bytes32[](3);
        bytes32[] memory itemHashes = new bytes32[](1);
        itemHashes[0] = keccak256("leaf");

        vm.expectRevert(abi.encodeWithSelector(MerklePathLengthMismatch.selector, 2, 3));
        Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
    }

    function test_calculateRootPaths_revertsOnPathTooLong() public {
        bytes32[] memory startPath = new bytes32[](256);
        bytes32[] memory endPath = new bytes32[](256);
        bytes32[] memory itemHashes = new bytes32[](1);
        itemHashes[0] = keccak256("leaf");

        vm.expectRevert(MerklePathOutOfBounds.selector);
        Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
    }

    function test_calculateRootPaths_revertsOnNothingToProve() public {
        bytes32[] memory startPath = new bytes32[](1);
        bytes32[] memory endPath = new bytes32[](1);
        bytes32[] memory itemHashes = new bytes32[](0);

        vm.expectRevert(MerkleNothingToProve.selector);
        Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
    }

    function test_calculateRootPaths_revertsOnIndexOrHeightMismatch() public {
        bytes32[] memory startPath = new bytes32[](1); // pathLength 1 means max 2 elements
        bytes32[] memory endPath = new bytes32[](1);
        bytes32[] memory itemHashes = new bytes32[](3); // 3 elements exceeds 2^1 = 2
        itemHashes[0] = keccak256("leaf0");
        itemHashes[1] = keccak256("leaf1");
        itemHashes[2] = keccak256("leaf2");

        vm.expectRevert(MerkleIndexOrHeightMismatch.selector);
        Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
    }

    function test_calculateRootPaths_revertsOnPathEmptyWithWrongParams() public {
        bytes32[] memory startPath = new bytes32[](0);
        bytes32[] memory endPath = new bytes32[](0);
        bytes32[] memory itemHashes = new bytes32[](2);
        itemHashes[0] = keccak256("leaf0");
        itemHashes[1] = keccak256("leaf1");

        vm.expectRevert(MerklePathEmpty.selector);
        Merkle.calculateRootPaths(startPath, endPath, 0, itemHashes);
    }

    // ============ efficientHash Tests ============

    function test_efficientHash_basic() public pure {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");

        bytes32 result = Merkle.efficientHash(a, b);
        bytes32 expected = keccak256(abi.encodePacked(a, b));

        assertEq(result, expected);
    }

    function test_efficientHash_orderMatters() public pure {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");

        bytes32 hashAB = Merkle.efficientHash(a, b);
        bytes32 hashReversed = Merkle.efficientHash(b, a);

        assertTrue(hashAB != hashReversed);
    }

    function testFuzz_efficientHash(bytes32 a, bytes32 b) public pure {
        bytes32 result = Merkle.efficientHash(a, b);
        bytes32 expected = keccak256(abi.encodePacked(a, b));

        assertEq(result, expected);
    }

    // ============ External Wrappers (for calldata) ============

    function externalCalculateRoot(
        bytes32[] calldata _path,
        uint256 _index,
        bytes32 _itemHash
    ) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _itemHash);
    }
}
