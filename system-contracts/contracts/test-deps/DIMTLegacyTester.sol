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

    /**
     * @dev Recreates the old L1Messenger MerkleTree root calculation logic
     * This mimics the algorithm from the draft-v29 L1Messenger contract
     */
    function calculateLegacyMerkleRoot(bytes32[] calldata leaves) public pure returns (bytes32) {
        uint256 leavesLength = leaves.length;

        // Legacy L1Messenger uses a fixed tree size of 16384 leaves (2^14)
        uint256 targetSize = 16384; // L2_TO_L1_LOGS_MERKLE_TREE_LEAVES

        // Create a working array padded to fixed size with DIMT zero values
        bytes32[] memory workingArray = new bytes32[](targetSize);
        for (uint256 i = 0; i < leavesLength; ++i) {
            workingArray[i] = leaves[i];
        }
        // Pad remaining elements with DIMT zero hash (L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH)
        for (uint256 i = leavesLength; i < targetSize; ++i) {
            workingArray[i] = ZERO_HASH;
        }

        uint256 nodesOnCurrentLevel = targetSize;

        // Bottom-up merkle tree construction (only works for power-of-2 trees)
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
        DynamicIncrementalMerkle.Bytes32PushTree memory dimtTree = DynamicIncrementalMerkle.Bytes32PushTree({
            _nextLeafIndex: 0,
            _sides: new bytes32[](15),
            _zeros: new bytes32[](15),
            _sidesLengthMemory: 0,
            _zerosLengthMemory: 0,
            _needsRootRecalculation: false
        });

        dimtTree.setupMemory(ZERO_HASH);

        uint256 leavesLength = leaves.length;
        for (uint256 i = 0; i < leavesLength; ++i) {
            dimtTree.pushMemory(leaves[i]);
        }

        dimtTree.extendUntilEndMemory();

        return dimtTree.rootMemory();
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
     * @dev Test lazy functionality by comparing pushLazy + root() vs regular pushes
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
        // Extend until end before getting root
        regularTree.extendUntilEnd(15);
        regularRoot = regularTree.root();

        // Lazy pushes
        for (uint256 i = 0; i < leavesLength; ++i) {
            lazyTree.pushLazy(leaves[i]);
        }
        // Need to extend until end before getting root for lazy operations
        lazyTree.extendUntilEnd(15);
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
        // Extend until end before getting root
        regularTree.extendUntilEnd(15);
        regularRoot = regularTree.root();

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
        // Ensure any remaining lazy operations are processed
        mixedTree.extendUntilEnd(15);
        mixedRoot = mixedTree.root();

        return (regularRoot, mixedRoot);
    }
}
