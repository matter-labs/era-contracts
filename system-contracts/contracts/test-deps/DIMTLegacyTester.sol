// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DynamicIncrementalMerkle} from "../libraries/DynamicIncrementalMerkle.sol";

/**
 * @dev Test contract to verify equivalence between DIMT and legacy L1Messenger MerkleTree
 */
contract DIMTLegacyTester {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    bytes32 public constant ZERO_HASH = hex"72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

    DynamicIncrementalMerkle.Bytes32PushTree private regularTree;
    DynamicIncrementalMerkle.Bytes32PushTree private lazyTree;
    DynamicIncrementalMerkle.Bytes32PushTree private mixedTree;

    error EmptyLeavesArray();

    /**
     * @dev Recreates the old L1Messenger MerkleTree root calculation logic
     * This mimics the algorithm from the draft-v29 L1Messenger contract
     */
    function calculateLegacyMerkleRoot(bytes32[] calldata leaves) public pure returns (bytes32) {
        if (leaves.length == 0) {
            revert EmptyLeavesArray();
        }

        // Create a working copy of the leaves array
        bytes32[] memory workingArray = new bytes32[](leaves.length);
        uint256 leavesLength = leaves.length;
        for (uint256 i = 0; i < leavesLength; ++i) {
            workingArray[i] = leaves[i];
        }

        uint256 nodesOnCurrentLevel = leavesLength;

        // Bottom-up merkle tree construction
        while (nodesOnCurrentLevel > 1) {
            nodesOnCurrentLevel /= 2;
            for (uint256 i = 0; i < nodesOnCurrentLevel; ++i) {
                workingArray[i] = keccak256(abi.encode(workingArray[2 * i], workingArray[2 * i + 1]));
            }
        }

        return workingArray[0];
    }

    /**
     * @dev Calculate DIMT root for given leaves using memory functions
     */
    function calculateDIMTRoot(bytes32[] calldata leaves) public pure returns (bytes32) {
        if (leaves.length == 0) {
            return bytes32(0);
        }

        DynamicIncrementalMerkle.Bytes32PushTree memory dimtTree;
        // Pre-allocate arrays for memory operations
        dimtTree._sides = new bytes32[](32);
        dimtTree._zeros = new bytes32[](32);

        // Setup DIMT with zero value
        dimtTree.setupMemory(ZERO_HASH);

        // Push all leaves to DIMT
        bytes32 dimtRoot;
        uint256 leavesLength = leaves.length;
        for (uint256 i = 0; i < leavesLength; ++i) {
            (, dimtRoot) = dimtTree.pushMemory(leaves[i]);
        }

        return dimtRoot;
    }

    /**
     * @dev Test equivalence between legacy and DIMT implementations
     */
    function testEquivalence(
        bytes32[] calldata leaves
    ) external pure returns (bool equivalent, bytes32 legacyRoot, bytes32 dimtRoot) {
        legacyRoot = calculateLegacyMerkleRoot(leaves);
        dimtRoot = calculateDIMTRoot(leaves);
        equivalent = (legacyRoot == dimtRoot);
    }

    /**
     * @dev Get hash using legacy method (keccak256(abi.encode(left, right)))
     */
    function getLegacyHash(bytes32 left, bytes32 right) external pure returns (bytes32) {
        return keccak256(abi.encode(left, right));
    }

    /**
     * @dev Batch test multiple leaf configurations
     */
    function batchTestEquivalence(
        bytes32[][] calldata leafSets
    ) external pure returns (bool[] memory equivalences, bytes32[] memory legacyRoots, bytes32[] memory dimtRoots) {
        equivalences = new bool[](leafSets.length);
        legacyRoots = new bytes32[](leafSets.length);
        dimtRoots = new bytes32[](leafSets.length);

        uint256 leafSetsLength = leafSets.length;
        for (uint256 i = 0; i < leafSetsLength; ++i) {
            bytes32 legacyRoot = calculateLegacyMerkleRoot(leafSets[i]);
            bytes32 dimtRoot = calculateDIMTRoot(leafSets[i]);
            bool equivalent = (legacyRoot == dimtRoot);

            equivalences[i] = equivalent;
            legacyRoots[i] = legacyRoot;
            dimtRoots[i] = dimtRoot;
        }
    }

    /**
     * @dev Test lazy functionality by comparing pushLazy + recalculateRoot vs regular pushes
     */
    function testLazyEquivalence(bytes32[] calldata leaves) external returns (bytes32 regularRoot, bytes32 lazyRoot) {
        if (leaves.length == 0) {
            return (bytes32(0), bytes32(0));
        }

        regularTree.reset(ZERO_HASH);
        lazyTree.reset(ZERO_HASH);

        uint256 leavesLength = leaves.length;

        // Regular pushes
        for (uint256 i = 0; i < leavesLength; ++i) {
            (, regularRoot) = regularTree.push(leaves[i]);
        }

        // Lazy pushes
        for (uint256 i = 0; i < leavesLength; ++i) {
            lazyTree.pushLazy(leaves[i]);
        }
        lazyRoot = lazyTree.root();

        return (regularRoot, lazyRoot);
    }

    /**
     * @dev Test mixed lazy and regular operations
     */
    function testMixedLazyOperations(
        bytes32[] calldata initialLeaves,
        bytes32[] calldata lazyLeaves,
        bytes32[] calldata finalLeaves
    ) external returns (bytes32 regularRoot, bytes32 mixedRoot) {
        regularTree.reset(ZERO_HASH);
        mixedTree.reset(ZERO_HASH);

        // Regular tree: push all leaves normally
        uint256 i;
        uint256 initialLeavesLength = initialLeaves.length;
        for (i = 0; i < initialLeavesLength; ++i) {
            regularTree.push(initialLeaves[i]);
        }
        uint256 lazyLeavesLength = lazyLeaves.length;
        for (i = 0; i < lazyLeavesLength; ++i) {
            regularTree.push(lazyLeaves[i]);
        }
        uint256 finalLeavesLength = finalLeaves.length;
        for (i = 0; i < finalLeavesLength; ++i) {
            (, regularRoot) = regularTree.push(finalLeaves[i]);
        }

        // Mixed tree: initial pushes, then lazy pushes, then final pushes
        for (i = 0; i < initialLeavesLength; ++i) {
            mixedTree.push(initialLeaves[i]);
        }
        for (i = 0; i < lazyLeavesLength; ++i) {
            mixedTree.pushLazy(lazyLeaves[i]);
        }
        for (i = 0; i < finalLeavesLength; ++i) {
            (, mixedRoot) = mixedTree.push(finalLeaves[i]);
        }

        return (regularRoot, mixedRoot);
    }

    /**
     * @dev Test lazy functionality for memory trees by comparing pushLazyMemory + recalculateRootMemory vs regular pushMemory
     */
    function testLazyEquivalenceMemory(
        bytes32[] calldata leaves
    ) external pure returns (bytes32 regularRoot, bytes32 lazyRoot) {
        if (leaves.length == 0) {
            return (bytes32(0), bytes32(0));
        }

        DynamicIncrementalMerkle.Bytes32PushTree memory memRegularTree;
        DynamicIncrementalMerkle.Bytes32PushTree memory memLazyTree;

        // Pre-allocate arrays for memory operations
        memRegularTree._sides = new bytes32[](32);
        memRegularTree._zeros = new bytes32[](32);
        memRegularTree._needsRootRecalculation = false;

        memLazyTree._sides = new bytes32[](32);
        memLazyTree._zeros = new bytes32[](32);
        memLazyTree._needsRootRecalculation = false;

        // Setup both trees
        memRegularTree.setupMemory(ZERO_HASH);
        memLazyTree.setupMemory(ZERO_HASH);

        uint256 leavesLength = leaves.length;

        // Regular pushes
        for (uint256 i = 0; i < leavesLength; ++i) {
            (, regularRoot) = memRegularTree.pushMemory(leaves[i]);
        }

        // Lazy pushes
        for (uint256 i = 0; i < leavesLength; ++i) {
            memLazyTree.pushLazyMemory(leaves[i]);
        }
        lazyRoot = memLazyTree.rootMemory();

        return (regularRoot, lazyRoot);
    }

    /**
     * @dev Test mixed lazy and regular operations for memory trees
     */
    function testMixedLazyOperationsMemory(
        bytes32[] calldata initialLeaves,
        bytes32[] calldata lazyLeaves,
        bytes32[] calldata finalLeaves
    ) external pure returns (bytes32 regularRoot, bytes32 mixedRoot) {
        DynamicIncrementalMerkle.Bytes32PushTree memory memRegularTree;
        DynamicIncrementalMerkle.Bytes32PushTree memory memMixedTree;

        // Pre-allocate arrays for memory operations
        memRegularTree._sides = new bytes32[](32);
        memRegularTree._zeros = new bytes32[](32);
        memRegularTree._needsRootRecalculation = false;

        memMixedTree._sides = new bytes32[](32);
        memMixedTree._zeros = new bytes32[](32);
        memMixedTree._needsRootRecalculation = false;

        memRegularTree.setupMemory(ZERO_HASH);
        memMixedTree.setupMemory(ZERO_HASH);

        // Regular tree: push all leaves normally
        uint256 i;
        uint256 initialLeavesLength = initialLeaves.length;
        for (i = 0; i < initialLeavesLength; ++i) {
            memRegularTree.pushMemory(initialLeaves[i]);
        }
        uint256 lazyLeavesLength = lazyLeaves.length;
        for (i = 0; i < lazyLeavesLength; ++i) {
            memRegularTree.pushMemory(lazyLeaves[i]);
        }
        uint256 finalLeavesLength = finalLeaves.length;
        for (i = 0; i < finalLeavesLength; ++i) {
            (, regularRoot) = memRegularTree.pushMemory(finalLeaves[i]);
        }

        // Mixed tree: initial pushes, then lazy pushes, then final pushes
        for (i = 0; i < initialLeavesLength; ++i) {
            memMixedTree.pushMemory(initialLeaves[i]);
        }
        for (i = 0; i < lazyLeavesLength; ++i) {
            memMixedTree.pushLazyMemory(lazyLeaves[i]);
        }
        for (i = 0; i < finalLeavesLength; ++i) {
            (, mixedRoot) = memMixedTree.pushMemory(finalLeaves[i]);
        }

        return (regularRoot, mixedRoot);
    }
}
