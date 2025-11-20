// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";
import {FullMerkleMemory} from "contracts/common/libraries/FullMerkleMemory.sol";
import {FullMerkleTest as FullMerkleTestContract} from "contracts/dev-contracts/test/FullMerkleTest.sol";

contract FullMerkleMemoryEdgeCasesTest is FullMerkleTest {
    using FullMerkleMemory for FullMerkleMemory.FullTree;

    /// @dev Test createTree() with zero max leaf number (should revert)
    function test_createTreeZeroMaxLeaf() public {
        FullMerkleMemory.FullTree memory memoryTree;

        vm.expectRevert(abi.encodeWithSelector(FullMerkleMemory.InvalidMaxLeafNumber.selector, 0));
        memoryTree.createTree(0);
    }

    /// @dev Test tree expansion when reaching power of 2 boundary (pushNewLeaf edge case)
    function test_pushNewLeafTreeExpansion() public {
        // Create tree with capacity for exactly 4 leaves (height 2)
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(8);

        // Fill to capacity that triggers expansion
        memoryTree.pushNewLeaf(bytes32(uint256(1)));
        memoryTree.pushNewLeaf(bytes32(uint256(2)));
        memoryTree.pushNewLeaf(bytes32(uint256(3)));
        memoryTree.pushNewLeaf(bytes32(uint256(4)));

        assertEq(memoryTree._leafNumber, 4);
        uint256 heightBefore = memoryTree._height;

        // Push 5th element - this should potentially trigger expansion logic
        memoryTree.pushNewLeaf(bytes32(uint256(5)));

        // Verify tree still works correctly
        assertEq(memoryTree._leafNumber, 5);
        assertTrue(memoryTree._height >= heightBefore);

        // Verify we can get a valid root
        bytes32 root = memoryTree.root();
        assertTrue(root != bytes32(0), "Root should be non-zero after expansion");
    }

    /// @dev Test node array initialization on first access (line 114)
    function test_nodeArrayInitialization() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(8);

        // Push elements to trigger node creation at different levels
        memoryTree.pushNewLeaf(bytes32(uint256(1)));
        memoryTree.pushNewLeaf(bytes32(uint256(2))); // This should create level 1 nodes

        // Verify node arrays are properly initialized
        assertTrue(memoryTree._nodes[1].length > 0, "Level 1 nodes should be initialized");

        // Push more to trigger higher level initialization
        memoryTree.pushNewLeaf(bytes32(uint256(3)));
        memoryTree.pushNewLeaf(bytes32(uint256(4))); // This should create level 2 nodes

        assertTrue(memoryTree._nodes[2].length > 0, "Level 2 nodes should be initialized");
    }

    /// @dev Test updateLeaf() with various edge cases
    function test_updateLeafEdgeCases() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(16);

        // Add several leaves
        for (uint256 i = 1; i <= 10; i++) {
            memoryTree.pushNewLeaf(bytes32(i));
        }

        bytes32 rootBefore = memoryTree.root();

        // Update first leaf (index 0)
        bytes32 newValue = keccak256("updated_first");
        memoryTree.updateLeaf(0, newValue);

        bytes32 rootAfter = memoryTree.root();
        assertTrue(rootBefore != rootAfter, "Root should change after update");

        // Update last leaf
        bytes32 newLastValue = keccak256("updated_last");
        memoryTree.updateLeaf(9, newLastValue);

        // Verify root changed again
        bytes32 finalRoot = memoryTree.root();
        assertTrue(rootAfter != finalRoot, "Root should change after last leaf update");
    }

    /// @dev Test updateAllLeaves() functionality
    function test_updateAllLeaves() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(8);

        // Add initial leaves
        memoryTree.pushNewLeaf(bytes32(uint256(1)));
        memoryTree.pushNewLeaf(bytes32(uint256(2)));
        memoryTree.pushNewLeaf(bytes32(uint256(3)));
        memoryTree.pushNewLeaf(bytes32(uint256(4)));

        bytes32 rootBefore = memoryTree.root();

        // Create new leaf values
        bytes32[] memory newLeaves = new bytes32[](4);
        newLeaves[0] = keccak256("new1");
        newLeaves[1] = keccak256("new2");
        newLeaves[2] = keccak256("new3");
        newLeaves[3] = keccak256("new4");

        // Update all leaves
        memoryTree.updateAllLeaves(newLeaves);

        bytes32 rootAfter = memoryTree.root();
        assertTrue(rootBefore != rootAfter, "Root should change after updating all leaves");

        // Verify leaf count remains the same
        assertEq(memoryTree._leafNumber, 4);
    }

    /// @dev Test updateAllNodesAtHeight() edge cases
    function test_updateAllNodesAtHeight() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(16);

        // Build tree with several leaves
        for (uint256 i = 1; i <= 8; i++) {
            memoryTree.pushNewLeaf(bytes32(i));
        }

        bytes32 rootBefore = memoryTree.root();

        // Update nodes at height 1 (leaf level + 1)
        bytes32[] memory newNodes = new bytes32[](4); // 8 leaves -> 4 nodes at height 1
        for (uint256 i = 0; i < 4; i++) {
            newNodes[i] = keccak256(abi.encodePacked("height1_node", i));
        }

        memoryTree.updateAllNodesAtHeight(1, newNodes);

        bytes32 rootAfter = memoryTree.root();
        assertTrue(rootBefore != rootAfter, "Root should change after updating nodes");
    }

    /// @dev Test tree behavior with single element
    function test_singleElementTree() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(1);

        bytes32 leafValue = keccak256("single");
        memoryTree.pushNewLeaf(leafValue);

        // For single element tree, root should equal the leaf value
        assertEq(memoryTree.root(), leafValue);
        assertEq(memoryTree._leafNumber, 1);
        assertEq(memoryTree._height, 0);
    }

    /// @dev Test zero value handling in calculations
    function test_zeroValueHandling() public {
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(8);

        // Push some zero values
        memoryTree.pushNewLeaf(bytes32(0));
        memoryTree.pushNewLeaf(zeroHash);
        memoryTree.pushNewLeaf(bytes32(uint256(1)));

        // Should handle zeros properly without errors
        bytes32 root1 = memoryTree.root();
        assertTrue(root1 != bytes32(0), "Root should be non-zero even with zero leaves");

        // Update with zero value
        memoryTree.updateLeaf(2, bytes32(0));
        bytes32 root2 = memoryTree.root();
        assertTrue(root1 != root2, "Root should change when updating to zero");
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
            // Reset storage tree
            merkleTest = new FullMerkleTestContract(zeroHash);
            FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(testSizes[s]);

            // Add same elements to both
            for (uint256 i = 0; i < testSizes[s]; i++) {
                bytes32 value = keccak256(abi.encodePacked("edge_test", s, i));
                merkleTest.pushNewLeaf(value);
                memoryTree.pushNewLeaf(value);
            }

            // Verify equivalence
            assertEq(merkleTest.root(), memoryTree.root(), "Storage and memory roots should match");
            assertEq(merkleTest.index(), memoryTree._leafNumber, "Leaf counts should match");
        }
    }

    /// @dev Test large tree operations for gas and correctness
    function test_largeTreeOperations() public {
        uint256 treeSize = 63; // Large non-power-of-2 number
        FullMerkleMemory.FullTree memory memoryTree = _setupMemoryTree(treeSize);

        // Fill tree
        for (uint256 i = 0; i < treeSize; i++) {
            memoryTree.pushNewLeaf(keccak256(abi.encodePacked("large_tree", i)));
        }

        bytes32 initialRoot = memoryTree.root();

        // Perform updates at various positions
        memoryTree.updateLeaf(0, keccak256("updated_0"));
        memoryTree.updateLeaf(31, keccak256("updated_31"));
        memoryTree.updateLeaf(62, keccak256("updated_62"));

        bytes32 finalRoot = memoryTree.root();
        assertTrue(initialRoot != finalRoot, "Root should change after updates");

        // Verify tree integrity
        assertEq(memoryTree._leafNumber, treeSize);
    }
}
