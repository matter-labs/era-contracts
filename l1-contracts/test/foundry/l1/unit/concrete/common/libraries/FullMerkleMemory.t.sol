// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FullMerkleMemory} from "contracts/common/libraries/FullMerkleMemory.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {FullMerkleTest as FullMerkleTestContract} from "contracts/dev-contracts/test/FullMerkleTest.sol";

contract FullMerkleMemoryTest is Test {
    using FullMerkleMemory for FullMerkleMemory.FullTree;

    bytes32 internal constant ZERO_HASH = keccak256(abi.encodePacked("ZERO"));

    /// @dev Test createTree() with ZERO max leaf number (should revert)
    function test_createTreeZeroMaxLeaf() public {
        FullMerkleMemory.FullTree memory memoryTree;

        vm.expectRevert(abi.encodeWithSelector(FullMerkleMemory.InvalidMaxLeafNumber.selector, 0));
        memoryTree.createTree(0);
    }

    function test_root_emptyTree() public pure {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(1);

        assertEq(memoryTree.root(), ZERO_HASH, "Root should be ZERO hash initially");
    }

    /// @dev Test tree behavior with single element
    function test_singleElementTree() public pure {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(1);

        bytes32 leafValue = keccak256("single");
        memoryTree.pushNewLeaf(leafValue);

        assertEq(memoryTree.root(), leafValue);
        assertEq(memoryTree._leafNumber, 1);
        assertEq(memoryTree._height, 0);
        assertEq(memoryTree._nodes[0][0], leafValue);
        assertEq(memoryTree._zeros[0], ZERO_HASH);
    }

    function test_pushNewLeaf_twoLeaves() public pure {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(2);

        bytes32 leaf0 = keccak256("Leaf 0");
        bytes32 leaf1 = keccak256("Leaf 1");
        memoryTree.pushNewLeaf(leaf0);
        memoryTree.pushNewLeaf(leaf1);

        assertEq(memoryTree._height, 1, "Height should be 1 after two inserts");
        assertEq(memoryTree._leafNumber, 2, "Leaf number should be 2 after two inserts");
        assertEq(memoryTree._nodes[0][0], leaf0, "Node 0,0 should be correctly inserted");
        assertEq(memoryTree._nodes[0][1], leaf1, "Node 0,1 should be correctly inserted");
        assertEq(memoryTree._nodes[1][0], Merkle.efficientHash(leaf0, leaf1), "Node 1,0 should be correctly inserted");
        assertEq(memoryTree._zeros[1], Merkle.efficientHash(ZERO_HASH, ZERO_HASH), "Zero 1 should be correct");
    }

    /// @dev Test updateAllLeaves() functionality
    function test_updateAllLeaves() public pure {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(8);

        memoryTree.pushNewLeaf(bytes32(uint256(1)));
        memoryTree.pushNewLeaf(bytes32(uint256(2)));
        memoryTree.pushNewLeaf(bytes32(uint256(3)));
        memoryTree.pushNewLeaf(bytes32(uint256(4)));

        bytes32[] memory newLeaves = new bytes32[](4);
        newLeaves[0] = keccak256("new1");
        newLeaves[1] = keccak256("new2");
        newLeaves[2] = keccak256("new3");
        newLeaves[3] = keccak256("new4");

        bytes32 returnedRoot = memoryTree.updateAllLeaves(newLeaves);

        bytes32 expectedRoot = Merkle.efficientHash(
            Merkle.efficientHash(newLeaves[0], newLeaves[1]),
            Merkle.efficientHash(newLeaves[2], newLeaves[3])
        );
        assertEq(returnedRoot, expectedRoot);
        assertEq(memoryTree.root(), expectedRoot);
        assertEq(memoryTree._leafNumber, 4);
    }

    /// @dev Test updateAllNodesAtHeight() edge cases
    function test_updateAllNodesAtHeight() public pure {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(16);

        for (uint256 i = 1; i <= 8; i++) {
            memoryTree.pushNewLeaf(bytes32(i));
        }

        // Update nodes at height 1 (leaf level + 1)
        bytes32[] memory newNodes = new bytes32[](4); // 8 leaves -> 4 nodes at height 1
        for (uint256 i = 0; i < 4; i++) {
            newNodes[i] = keccak256(abi.encodePacked("height1_node", i));
        }

        bytes32 returnedRoot = memoryTree.updateAllNodesAtHeight(1, newNodes);

        bytes32 expectedRoot = Merkle.efficientHash(
            Merkle.efficientHash(newNodes[0], newNodes[1]),
            Merkle.efficientHash(newNodes[2], newNodes[3])
        );
        assertEq(returnedRoot, expectedRoot);
        assertEq(memoryTree.root(), expectedRoot);
    }

    /// @dev Test memory tree vs storage tree equivalence for edge cases
    function test_memoryStorageEquivalenceEdgeCases() public {
        // Test with power-of-2 boundaries
        uint256[] memory testSizes = new uint256[](5);
        testSizes[0] = 1;
        testSizes[1] = 2;
        testSizes[2] = 4;
        testSizes[3] = 8;
        testSizes[4] = 15; // Non-power-of-2

        for (uint256 s = 0; s < testSizes.length; s++) {
            FullMerkleTestContract storageTree = new FullMerkleTestContract(ZERO_HASH);
            FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(testSizes[s]);

            for (uint256 i = 0; i < testSizes[s]; i++) {
                bytes32 value = keccak256(abi.encodePacked("edge_test", s, i));
                storageTree.pushNewLeaf(value);
                memoryTree.pushNewLeaf(value);
            }

            assertEq(storageTree.root(), memoryTree.root(), "Storage and memory roots should match");
            assertEq(storageTree.index(), memoryTree._leafNumber, "Leaf counts should match");
        }
    }

    /// @dev Updates at the first, a middle and the last leaf of a large non-power-of-2 tree match the storage tree.
    function test_largeTreeOperations() public {
        uint256 treeSize = 63;
        FullMerkleTestContract storageTree = new FullMerkleTestContract(ZERO_HASH);
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(treeSize);

        for (uint256 i = 0; i < treeSize; i++) {
            bytes32 value = keccak256(abi.encodePacked("large_tree", i));
            storageTree.pushNewLeaf(value);
            memoryTree.pushNewLeaf(value);
        }

        uint256[3] memory updatedIndices = [uint256(0), 31, 62];
        for (uint256 i = 0; i < updatedIndices.length; i++) {
            bytes32 value = keccak256(abi.encodePacked("updated", updatedIndices[i]));
            storageTree.updateLeaf(updatedIndices[i], value);
            memoryTree.updateLeaf(updatedIndices[i], value);
        }

        assertEq(memoryTree.root(), storageTree.root(), "Storage and memory roots should match");
        assertEq(memoryTree._leafNumber, treeSize);
    }

    function _setupMemoryTree(uint256 _maxLeafNumber) internal pure returns (FullMerkleMemory.FullTree memory) {
        FullMerkleMemory.FullTree memory memoryTree;
        memoryTree.createTree(_maxLeafNumber);
        memoryTree.setup(ZERO_HASH);
        return memoryTree;
    }
}
