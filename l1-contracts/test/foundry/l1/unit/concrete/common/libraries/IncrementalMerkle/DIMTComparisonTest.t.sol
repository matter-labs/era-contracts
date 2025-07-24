// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";
import {FullMerkle} from "contracts/common/libraries/FullMerkle.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";
import {FullMerkleTest} from "contracts/dev-contracts/test/FullMerkleTest.sol";

/**
 * @dev Tests DIMT behavior, comparison with FullMerkle
 */
contract DIMTComparisonTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;
    using FullMerkle for FullMerkle.FullTree;

    DynamicIncrementalMerkle.Bytes32PushTree dimtStorage;
    FullMerkle.FullTree fullMerkle;
    
    // Test constants
    bytes32 constant ZERO_HASH = hex"72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";
    uint256 constant L2_TO_L1_LOGS_MERKLE_TREE_DEPTH = 14;
    
    function setUp() public {
        dimtStorage.setup(ZERO_HASH);
        fullMerkle.setup(ZERO_HASH);
    }

    /**
     * @notice Main test: DIMT and FullMerkle produce identical roots for same leaf sequences
     * @dev This is the key test proving DIMT behaves like a normal Merkle tree
     */
    function testDIMTvsFullMerkle_IdenticalRoots() public {
        bytes32[] memory leaves = new bytes32[](8);
        for (uint256 i = 0; i < leaves.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(i));
        }
        
        // Add leaves to both trees
        for (uint256 i = 0; i < leaves.length; i++) {
            dimtStorage.push(leaves[i]);
            fullMerkle.pushNewLeaf(leaves[i]);
        }
        
        // Both trees should extend to same final depth for comparison
        uint8 finalDepth = 4; // 16 leaves capacity
        dimtStorage.extendUntilEnd(finalDepth);
        
        bytes32 dimtRoot = dimtStorage.root();
        bytes32 fullMerkleRoot = fullMerkle.root();
        
        console.log("DIMT Root:");
        console.logBytes32(dimtRoot);
        console.log("FullMerkle Root:");
        console.logBytes32(fullMerkleRoot);
        
        assertEq(dimtRoot, fullMerkleRoot, "DIMT and FullMerkle should produce identical roots");
    }

    /**
     * @notice Test dynamic growth behavior - trees should behave identically when growing
     */
    function testDynamicGrowth_IdenticalBehavior() public {
        // Start with 2 leaves, then grow to 3 (forces growth)
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        
        // Add first 2 leaves
        dimtStorage.push(leaf1);
        dimtStorage.push(leaf2);
        fullMerkle.pushNewLeaf(leaf1);
        fullMerkle.pushNewLeaf(leaf2);
        
        // Check roots before growth
        bytes32 dimtRoot2 = dimtStorage.root();
        bytes32 fullRoot2 = fullMerkle.root();
        assertEq(dimtRoot2, fullRoot2, "Roots should match before growth");
        
        // Add third leaf (triggers growth in DIMT)
        dimtStorage.push(leaf3);
        fullMerkle.pushNewLeaf(leaf3);
        
        // Check roots after growth
        bytes32 dimtRoot3 = dimtStorage.root();
        bytes32 fullRoot3 = fullMerkle.root();
        assertEq(dimtRoot3, fullRoot3, "Roots should match after growth");
        
        console.log("After growth - DIMT height:", dimtStorage.height());
        console.log("After growth - FullMerkle height:", fullMerkle._height);
    }

    /**
     * @notice Test tree growth through power-of-2 boundaries
     */
    function testTreeGrowth() public {
        // Start with empty tree
        assertEq(dimtStorage.height(), 0, "Initial height should be 0");
        
        // Add first leaf - should not grow yet
        dimtStorage.push(keccak256("first"));
        assertEq(dimtStorage.height(), 0, "Height should still be 0 after first leaf");
        
        // Add second leaf - should grow to height 1
        dimtStorage.push(keccak256("second"));
        assertEq(dimtStorage.height(), 1, "Height should be 1 after second leaf");
        
        // Add third leaf - should grow to height 2  
        dimtStorage.push(keccak256("third"));
        assertEq(dimtStorage.height(), 2, "Height should be 2 after third leaf");
        
        console.log("Tree grew correctly through power-of-2 boundaries");
    }

    /**
     * @notice Test consistency - rebuilding tree should produce identical results
     */
    function testConsistentResults() public {
        bytes32[] memory testLogs = new bytes32[](4);
        testLogs[0] = bytes32(uint256(1));
        testLogs[1] = bytes32(uint256(2));
        testLogs[2] = bytes32(uint256(3));
        testLogs[3] = bytes32(uint256(4));
        
        // Build tree first time
        for (uint i = 0; i < testLogs.length; i++) {
            dimtStorage.push(testLogs[i]);
        }
        dimtStorage.extendUntilEnd(10);
        bytes32 root1 = dimtStorage.root();
        
        // Clear and rebuild
        dimtStorage.clear();
        dimtStorage.setup(ZERO_HASH);
        
        for (uint i = 0; i < testLogs.length; i++) {
            dimtStorage.push(testLogs[i]);
        }
        dimtStorage.extendUntilEnd(10);
        bytes32 root2 = dimtStorage.root();
        
        assertEq(root1, root2, "Rebuilding should produce identical root");
        
        console.log("Consistent root:");
        console.logBytes32(root1);
    }

    /**
     * @notice Test single leaf tree behavior
     */
    function testSingleLeaf_IdenticalRoots() public {
        bytes32 singleLeaf = keccak256("single");
        
        dimtStorage.push(singleLeaf);
        fullMerkle.pushNewLeaf(singleLeaf);
        
        bytes32 dimtRoot = dimtStorage.root();
        bytes32 fullRoot = fullMerkle.root();
        
        assertEq(dimtRoot, fullRoot, "Single leaf roots should match");
    }
}