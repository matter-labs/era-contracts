// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";
import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";

contract IncrementalMerkleTestTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    IncrementalMerkleTest merkleTest;
    bytes32 constant zero = 0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba;

    function setUp() public {
        merkleTest = new IncrementalMerkleTest(zero);
    }

    function setUpMemory() public returns (DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory) {
        merkleTestMemory = DynamicIncrementalMerkleMemory.Bytes32PushTree(
            0,
            new bytes32[](14),
            new bytes32[](14),
            0,
            0,
            false,
            bytes32(0)
        );
        merkleTestMemory.setup(zero);
    }

    /// @dev Test basic setup and initialization (storage vs memory)
    function testSetup() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        // Storage tree
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 0);

        // Memory tree
        assertEq(merkleTestMemory.height(), 0);
        assertEq(merkleTestMemory.index(), 0);

        // Both should have empty root initially
        assertEq(merkleTest.root(), bytes32(0));
        assertEq(merkleTestMemory.root(), bytes32(0));
    }

    /// @dev Test single element insertion (storage vs memory)
    function testSingleElement() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        bytes32 testValue = bytes32(uint256(0));

        // Storage tree
        merkleTest.push(testValue);

        // Memory tree
        merkleTestMemory.push(testValue);

        // Verify storage tree state
        assertEq(merkleTest.root(), testValue);
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 1);

        // Verify memory tree state
        assertEq(merkleTestMemory.root(), testValue);
        assertEq(merkleTestMemory.height(), 0);
        assertEq(merkleTestMemory.index(), 1);

        // Compare storage vs memory
        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.height(), merkleTestMemory.height());
        assertEq(merkleTest.index(), merkleTestMemory.index());
    }

    /// @dev Test two elements (storage vs memory) - triggers first tree expansion
    function testTwoElements() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        // Storage tree
        merkleTest.push(bytes32(uint256(0)));
        merkleTest.push(bytes32(uint256(1)));

        // Memory tree
        merkleTestMemory.push(bytes32(uint256(0)));
        merkleTestMemory.push(bytes32(uint256(1)));

        bytes32 expectedRoot = keccak256(abi.encodePacked(uint256(0), uint256(1)));

        // Verify both trees
        assertEq(merkleTest.root(), expectedRoot);
        assertEq(merkleTest.height(), 1);
        assertEq(merkleTest.index(), 2);

        assertEq(merkleTestMemory.root(), expectedRoot);
        assertEq(merkleTestMemory.height(), 1);
        assertEq(merkleTestMemory.index(), 2);

        // Compare storage vs memory
        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.height(), merkleTestMemory.height());
        assertEq(merkleTest.index(), merkleTestMemory.index());
    }

    /// @dev Test lazy vs regular pushes in memory (single element)
    function testLazyVsRegularSingle() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        bytes32 testValue = keccak256("test");

        merkleRegular.push(testValue);
        merkleLazy.pushLazy(testValue);

        assertEq(merkleRegular.root(), merkleLazy.root());
        assertEq(merkleRegular.index(), merkleLazy.index());
        assertEq(merkleRegular.height(), merkleLazy.height());
    }

    /// @dev Test mixed lazy and regular operations
    function testMixedLazyRegular() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMixed = setUpMemory();

        // Regular approach
        merkleRegular.push(bytes32(uint256(0)));
        merkleRegular.push(bytes32(uint256(1)));
        merkleRegular.push(bytes32(uint256(2)));
        merkleRegular.push(bytes32(uint256(3)));

        // Mixed approach - some lazy, some regular
        merkleMixed.pushLazy(bytes32(uint256(0)));
        merkleMixed.pushLazy(bytes32(uint256(1)));
        merkleMixed.push(bytes32(uint256(2))); // This should process pending leaves
        merkleMixed.push(bytes32(uint256(3)));

        // Both should produce the same root
        assertEq(merkleRegular.root(), merkleMixed.root());
        assertEq(merkleRegular.index(), merkleMixed.index());
        assertEq(merkleRegular.height(), merkleMixed.height());
    }

    /// @dev Test sequential values comparing storage tree with memory trees
    function testSequentialValues() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        uint256 numElements = 42;

        // Storage tree pushes
        for (uint256 i = 0; i < numElements; i++) {
            merkleTest.push(bytes32(i));
        }

        // Memory tree pushes
        for (uint256 i = 0; i < numElements; i++) {
            merkleTestMemory.push(bytes32(i));
        }

        // Compare storage vs memory
        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.index(), merkleTestMemory.index());
        assertEq(merkleTest.height(), merkleTestMemory.height());
    }

    /// @dev Test the original failing lazy push batch processing
    function testPushLazyBatchProcessing() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestLazy = setUpMemory();

        uint256 numElements = 42;

        // Regular pushes
        for (uint256 i = 0; i < numElements; i++) {
            merkleTestRegular.push(bytes32(i));
        }

        // Lazy pushes
        for (uint256 i = 0; i < numElements; i++) {
            merkleTestLazy.pushLazy(bytes32(i));
        }

        // Both should produce the same root
        assertEq(merkleTestRegular.root(), merkleTestLazy.root());
        assertEq(merkleTestRegular.index(), merkleTestLazy.index());
        assertEq(merkleTestRegular.height(), merkleTestLazy.height());
    }

    /// @dev Test non-sequential arbitrary values
    function testNonSequentialOddIndex() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        bytes32[] memory values = new bytes32[](7);
        values[0] = keccak256("value0");
        values[1] = keccak256("value1");
        values[2] = bytes32(uint256(0xAAAAAAA));
        values[3] = bytes32(uint256(0xBBBBBBB));
        values[4] = keccak256(abi.encodePacked(block.timestamp));
        values[5] = bytes32(type(uint256).max);
        values[6] = keccak256("final_odd");

        for (uint256 i = 0; i < values.length; i++) {
            DynamicIncrementalMerkleMemory.push(merkleRegular, values[i]);
            DynamicIncrementalMerkleMemory.pushLazy(merkleLazy, values[i]);
        }

        bytes32 finalOdd = bytes32(uint256(0x123456789));
        DynamicIncrementalMerkleMemory.push(merkleRegular, finalOdd);
        DynamicIncrementalMerkleMemory.pushLazy(merkleLazy, finalOdd);

        // This tests the _lastLeafValue reconstruction path
        assertEq(DynamicIncrementalMerkleMemory.root(merkleRegular), DynamicIncrementalMerkleMemory.root(merkleLazy));
        assertEq(merkleRegular.index(), merkleLazy.index());
        assertEq(
            DynamicIncrementalMerkleMemory.height(merkleRegular),
            DynamicIncrementalMerkleMemory.height(merkleLazy)
        );
    }

    /// @dev Test edge cases - zero values and extreme values
    function testEdgeCases() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        // Test with edge case values
        bytes32[] memory edgeValues = new bytes32[](5);
        edgeValues[0] = bytes32(0);
        edgeValues[1] = bytes32(type(uint256).max);
        edgeValues[2] = bytes32(uint256(1));
        edgeValues[3] = zero;
        edgeValues[4] = keccak256("edge");

        for (uint256 i = 0; i < edgeValues.length; i++) {
            merkleRegular.push(edgeValues[i]);
            merkleLazy.pushLazy(edgeValues[i]);
        }

        assertEq(merkleRegular.root(), merkleLazy.root());
        assertEq(merkleRegular.index(), merkleLazy.index());
        assertEq(merkleRegular.height(), merkleLazy.height());
    }

    /// @dev Test power-of-2 boundary expansions
    function testPowerOfTwoBoundaries() public {
        // Test critical power-of-2 transitions
        uint256[] memory boundaries = new uint256[](6);
        boundaries[0] = 1; // Single element
        boundaries[1] = 2; // First expansion
        boundaries[2] = 4; // Second expansion
        boundaries[3] = 8; // Third expansion
        boundaries[4] = 16; // Fourth expansion
        boundaries[5] = 32; // Fifth expansion

        for (uint256 b = 0; b < boundaries.length; b++) {
            DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
            DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

            for (uint256 i = 0; i < boundaries[b]; i++) {
                bytes32 value = keccak256(abi.encodePacked("boundary", b, "element", i));
                merkleRegular.push(value);
                merkleLazy.pushLazy(value);
            }

            assertEq(merkleRegular.root(), merkleLazy.root(), "Boundary test failed");
            assertEq(merkleRegular.height(), merkleLazy.height(), "Height mismatch");
            assertEq(merkleRegular.index(), merkleLazy.index(), "Index mismatch");
        }
    }

    /// @dev Test intermediate root calls during lazy operations
    function testIntermediateRoots() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        // Test that calling root() at various stages works correctly
        for (uint256 i = 0; i < 15; i++) {
            bytes32 value = keccak256(abi.encodePacked("intermediate", i));
            merkleRegular.push(value);
            merkleLazy.pushLazy(value);

            // Check root after each insertion
            assertEq(merkleRegular.root(), merkleLazy.root(), "Intermediate root mismatch");
            assertEq(merkleRegular.index(), merkleLazy.index(), "Index mismatch");
            assertEq(merkleRegular.height(), merkleLazy.height(), "Height mismatch");
        }
    }

    /// @dev Test storage vs memory with larger dataset
    function testStorageVsMemoryLarge() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        uint256 numElements = 25;

        // Push elements to both trees
        for (uint256 i = 0; i < numElements; i++) {
            bytes32 value = keccak256(abi.encodePacked("element", i));
            merkleTest.push(value);
            merkleTestMemory.push(value);
        }

        // Compare storage vs memory
        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.index(), merkleTestMemory.index());
        assertEq(merkleTest.height(), merkleTestMemory.height());
    }

    /// @dev Test large tree with various data patterns
    function testLargeTreeVariedPatterns() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        uint256 numElements = 100;

        for (uint256 i = 0; i < numElements; i++) {
            bytes32 value;
            // Mix different data patterns to stress test
            if (i % 5 == 0) {
                value = keccak256(abi.encodePacked("pattern", i));
            } else if (i % 5 == 1) {
                value = bytes32(i);
            } else if (i % 5 == 2) {
                value = bytes32(type(uint256).max - i);
            } else if (i % 5 == 3) {
                value = bytes32(0);
            } else {
                value = keccak256(abi.encodePacked(i, block.timestamp));
            }

            merkleRegular.push(value);
            merkleLazy.pushLazy(value);
        }

        assertEq(merkleRegular.root(), merkleLazy.root());
        assertEq(merkleRegular.index(), merkleLazy.index());
        assertEq(merkleRegular.height(), merkleLazy.height());
    }

    /// @dev Test reset() function - should clear and reinitialize the tree
    function testReset() public {
        merkleTest.push(bytes32(uint256(1)));
        merkleTest.push(bytes32(uint256(2)));
        merkleTest.push(bytes32(uint256(3)));

        // Verify tree has data
        assertTrue(merkleTest.root() != bytes32(0));
        assertEq(merkleTest.index(), 3);
        assertTrue(merkleTest.height() > 0);

        // Reset with different zero value
        bytes32 newZero = keccak256("NEW_ZERO");
        merkleTest.reset(newZero);

        // Verify tree is reset
        assertEq(merkleTest.root(), bytes32(0));
        assertEq(merkleTest.index(), 0);
        assertEq(merkleTest.height(), 0);

        // Verify it works with new zero value
        merkleTest.push(bytes32(uint256(42)));
        assertEq(merkleTest.root(), bytes32(uint256(42)));
    }

    /// @dev Test clear() function by testing reset() behavior
    function testClear() public {
        merkleTest.push(bytes32(uint256(100)));
        merkleTest.push(bytes32(uint256(200)));

        // Verify tree has data before reset
        assertTrue(merkleTest.root() != bytes32(0));
        assertEq(merkleTest.index(), 2);

        // Reset should call clear internally
        merkleTest.reset(zero);

        // Verify tree is cleared
        assertEq(merkleTest.root(), bytes32(0));
        assertEq(merkleTest.index(), 0);
        assertEq(merkleTest.height(), 0);
    }

    /// @dev Test extendUntilEnd() edge cases
    function testExtendUntilEndEdgeCases() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Test extending from empty tree (nextLeafIndex == 0)
        merkleMemory._nextLeafIndex = 0;
        merkleMemory._sides = new bytes32[](1);
        merkleMemory._zeros = new bytes32[](1);
        merkleMemory._sides[0] = zero;
        merkleMemory._zeros[0] = zero;
        merkleMemory._sidesLengthMemory = 1;
        merkleMemory._zerosLengthMemory = 1;

        // Extend the tree to a larger depth
        bytes32[] memory newSides = new bytes32[](5);
        bytes32[] memory newZeros = new bytes32[](5);
        for (uint i = 0; i < 1; i++) {
            newSides[i] = merkleMemory._sides[i];
            newZeros[i] = merkleMemory._zeros[i];
        }
        merkleMemory._sides = newSides;
        merkleMemory._zeros = newZeros;

        // This should extend the tree properly
        DynamicIncrementalMerkleMemory.extendUntilEnd(merkleMemory);

        // Verify extension worked
        assertEq(merkleMemory._sidesLengthMemory, 5);
        assertEq(merkleMemory._zerosLengthMemory, 5);
        assertTrue(merkleMemory._sides[0] == zero); // Should set _sides[0] = currentZero when _nextLeafIndex == 0
    }

    /// @dev Gas comparison test - performance validation
    function testGasComparison() public {
        uint256 numElements = 50;

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        uint256 gasStartRegular = gasleft();

        for (uint256 i = 0; i < numElements; i++) {
            merkleRegular.push(keccak256(abi.encodePacked("element", i)));
        }
        bytes32 regularRoot = merkleRegular.root();
        uint256 gasUsedRegular = gasStartRegular - gasleft();

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();
        uint256 gasStartLazy = gasleft();

        for (uint256 i = 0; i < numElements; i++) {
            merkleLazy.pushLazy(keccak256(abi.encodePacked("element", i)));
        }
        bytes32 lazyRoot = merkleLazy.root();
        uint256 gasUsedLazy = gasStartLazy - gasleft();

        // Verify correctness
        assertEq(regularRoot, lazyRoot);

        // Lazy should be significantly more efficient
        assertLt(gasUsedLazy, gasUsedRegular, "Lazy should use less gas");

        // Log for visibility
        emit log_named_uint("Regular gas used", gasUsedRegular);
        emit log_named_uint("Lazy gas used", gasUsedLazy);
        emit log_named_uint("Gas savings", gasUsedRegular - gasUsedLazy);

        // Verify significant savings (should be >40%)
        uint256 savingsPercent = ((gasUsedRegular - gasUsedLazy) * 100) / gasUsedRegular;
        assertGt(savingsPercent, 40, "Should achieve significant gas savings");
    }

    /// @dev Test createTree() function initialization
    function testCreateTreeInitialization() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory;

        // Initialize with createTree
        DynamicIncrementalMerkleMemory.createTree(merkleMemory, 10);

        // Verify proper initialization
        assertEq(merkleMemory._sides.length, 10);
        assertEq(merkleMemory._zeros.length, 10);
        assertEq(merkleMemory._sidesLengthMemory, 0);
        assertEq(merkleMemory._zerosLengthMemory, 0);
        assertEq(merkleMemory._nextLeafIndex, 0);
        assertFalse(merkleMemory._needsRootRecalculation);
        assertEq(merkleMemory._lastLeafValue, bytes32(0));
    }

    /// @dev Test _recalculateRoot() with empty tree (leafCount == 0)
    function testRecalculateRootEmptyTree() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Ensure tree is empty
        merkleMemory._nextLeafIndex = 0;

        // Call root() which internally calls _recalculateRoot()
        bytes32 rootResult = merkleMemory.root();

        // Should return bytes32(0) for empty tree
        assertEq(rootResult, bytes32(0));
    }

    /// @dev Test various extendUntilEnd() scenarios for memory tree
    function testExtendUntilEndScenarios() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Setup initial state with some elements
        merkleMemory.push(bytes32(uint256(1)));
        merkleMemory.push(bytes32(uint256(2)));

        // Manually extend the arrays to test extending behavior
        bytes32[] memory newSides = new bytes32[](8);
        bytes32[] memory newZeros = new bytes32[](8);

        // Copy existing data
        for (uint i = 0; i < merkleMemory._sidesLengthMemory && i < newSides.length; i++) {
            newSides[i] = merkleMemory._sides[i];
        }
        for (uint i = 0; i < merkleMemory._zerosLengthMemory && i < newZeros.length; i++) {
            newZeros[i] = merkleMemory._zeros[i];
        }

        merkleMemory._sides = newSides;
        merkleMemory._zeros = newZeros;

        // Test extension
        DynamicIncrementalMerkleMemory.extendUntilEnd(merkleMemory);

        // Verify extension completed
        assertEq(merkleMemory._sidesLengthMemory, 8);
        assertEq(merkleMemory._zerosLengthMemory, 8);
        assertFalse(merkleMemory._needsRootRecalculation);

        // Verify we can still get a valid root
        bytes32 rootAfterExtend = merkleMemory.root();
        assertTrue(rootAfterExtend != bytes32(0));
    }

    /// @dev Test comprehensive storage vs memory equivalence
    function testStorageMemoryEquivalenceComprehensive() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Test various scenarios
        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 1; // Single element
        testSizes[1] = 7; // Odd number
        testSizes[2] = 16; // Power of 2
        testSizes[3] = 33; // After expansion

        for (uint256 t = 0; t < testSizes.length; t++) {
            // Reset trees
            merkleTest = new IncrementalMerkleTest(zero);
            merkleMemory = setUpMemory();

            // Push same elements to both
            for (uint256 i = 0; i < testSizes[t]; i++) {
                bytes32 value = keccak256(abi.encodePacked("test", t, "elem", i));
                merkleTest.push(value);
                merkleMemory.push(value);
            }

            // Verify equivalence
            assertEq(merkleTest.root(), merkleMemory.root(), "Root mismatch in comprehensive test");
            assertEq(merkleTest.height(), merkleMemory.height(), "Height mismatch in comprehensive test");
            assertEq(merkleTest.index(), merkleMemory.index(), "Index mismatch in comprehensive test");
        }
    }
}
