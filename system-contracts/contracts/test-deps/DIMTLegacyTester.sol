// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DynamicIncrementalMerkle} from "../libraries/DynamicIncrementalMerkle.sol";

/**
 * @dev Test contract to verify equivalence between DIMT and legacy L1Messenger MerkleTree
 */
contract DIMTLegacyTester {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    bytes32 public constant ZERO_HASH = hex"72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

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
}
