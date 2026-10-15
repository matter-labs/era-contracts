// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";
import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";

contract DynamicIncrementalMerkleMemoryTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    IncrementalMerkleTest internal merkleTest;
    bytes32 internal constant ZERO = 0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba;

    function setUp() public {
        merkleTest = new IncrementalMerkleTest(ZERO);
    }

    function setUpMemory()
        public
        pure
        returns (DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory)
    {
        merkleTestMemory = DynamicIncrementalMerkleMemory.Bytes32PushTree({
            _nextLeafIndex: 0,
            _sides: new bytes32[](14),
            _zeros: new bytes32[](14),
            _sidesLengthMemory: 0,
            _zerosLengthMemory: 0,
            _needsRootRecalculation: false,
            _lastLeafValue: bytes32(0)
        });
        merkleTestMemory.setup(ZERO);
    }

    /// @dev Test basic setup and initialization (storage vs memory)
    function testSetup() public view {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 0);

        assertEq(merkleTestMemory.height(), 0);
        assertEq(merkleTestMemory.index(), 0);
        assertEq(merkleTestMemory._zeros[0], ZERO);
        assertEq(merkleTestMemory._zerosLengthMemory, 1);

        assertEq(merkleTest.root(), bytes32(0));
        assertEq(merkleTestMemory.root(), bytes32(0));
    }

    /// @dev Test single element insertion (storage vs memory)
    function testSingleElement() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        bytes32 testValue = bytes32(uint256(0));

        merkleTest.push(testValue);

        merkleTestMemory.push(testValue);

        assertEq(merkleTest.root(), testValue);
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 1);

        assertEq(merkleTestMemory.root(), testValue);
        assertEq(merkleTestMemory.height(), 0);
        assertEq(merkleTestMemory.index(), 1);

        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.height(), merkleTestMemory.height());
        assertEq(merkleTest.index(), merkleTestMemory.index());
    }

    /// @dev Test two elements (storage vs memory) - triggers first tree expansion
    function testTwoElements() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        merkleTest.push(bytes32(uint256(0)));
        merkleTest.push(bytes32(uint256(1)));

        merkleTestMemory.push(bytes32(uint256(0)));
        merkleTestMemory.push(bytes32(uint256(1)));

        bytes32 expectedRoot = keccak256(abi.encodePacked(uint256(0), uint256(1)));

        assertEq(merkleTest.root(), expectedRoot);
        assertEq(merkleTest.height(), 1);
        assertEq(merkleTest.index(), 2);

        assertEq(merkleTestMemory.root(), expectedRoot);
        assertEq(merkleTestMemory.height(), 1);
        assertEq(merkleTestMemory.index(), 2);

        assertEq(merkleTest.root(), merkleTestMemory.root());
        assertEq(merkleTest.height(), merkleTestMemory.height());
        assertEq(merkleTest.index(), merkleTestMemory.index());
    }

    function test_push_fourLeaves() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");
        bytes32 leaf3 = keccak256("leaf3");
        bytes32 leaf4 = keccak256("leaf4");

        (uint256 idx1, ) = merkleTestMemory.push(leaf1);
        (uint256 idx2, ) = merkleTestMemory.push(leaf2);
        (uint256 idx3, ) = merkleTestMemory.push(leaf3);
        (uint256 idx4, bytes32 newRoot) = merkleTestMemory.push(leaf4);

        assertEq(idx1, 0);
        assertEq(idx2, 1);
        assertEq(idx3, 2);
        assertEq(idx4, 3);

        bytes32 expectedRoot = Merkle.efficientHash(
            Merkle.efficientHash(leaf1, leaf2),
            Merkle.efficientHash(leaf3, leaf4)
        );
        assertEq(newRoot, expectedRoot);
        assertEq(merkleTestMemory.root(), expectedRoot);
        assertEq(merkleTestMemory.index(), 4);
        assertEq(merkleTestMemory.height(), 2);
    }

    function test_pushLazy_singleLeaf() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        uint256 leafIndex = merkleTestMemory.pushLazy(keccak256("leaf1"));

        assertEq(leafIndex, 0);
        assertEq(merkleTestMemory._nextLeafIndex, 1);
    }

    function testFuzz_pushLazy_matchesPush(bytes32 _leaf1, bytes32 _leaf2) public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        merkleRegular.push(_leaf1);
        (, bytes32 expectedRoot) = merkleRegular.push(_leaf2);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();
        merkleLazy.pushLazy(_leaf1);
        merkleLazy.pushLazy(_leaf2);

        assertEq(merkleLazy.root(), expectedRoot);
    }

    /// @dev Test mixed lazy and regular operations
    function testMixedLazyRegular() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMixed = setUpMemory();

        merkleRegular.push(bytes32(uint256(0)));
        merkleRegular.push(bytes32(uint256(1)));
        merkleRegular.push(bytes32(uint256(2)));
        merkleRegular.push(bytes32(uint256(3)));

        // Mixed approach - some lazy, some regular
        merkleMixed.pushLazy(bytes32(uint256(0)));
        merkleMixed.pushLazy(bytes32(uint256(1)));
        merkleMixed.push(bytes32(uint256(2))); // This should process pending leaves
        merkleMixed.push(bytes32(uint256(3)));

        assertEq(merkleRegular.root(), merkleMixed.root());
        assertEq(merkleRegular.index(), merkleMixed.index());
        assertEq(merkleRegular.height(), merkleMixed.height());
    }

    /// @dev Test intermediate root calls during lazy operations
    function testIntermediateRoots() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleRegular = setUpMemory();
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleLazy = setUpMemory();

        // Test that calling root() at various stages works correctly
        for (uint256 i = 0; i < 15; i++) {
            bytes32 value = keccak256(abi.encodePacked("intermediate", i));
            merkleRegular.push(value);
            merkleLazy.pushLazy(value);

            assertEq(merkleRegular.root(), merkleLazy.root(), "Intermediate root mismatch");
            assertEq(merkleRegular.index(), merkleLazy.index(), "Index mismatch");
            assertEq(merkleRegular.height(), merkleLazy.height(), "Height mismatch");
        }
    }

    /// @dev Test large tree with various data patterns
    function testLargeTreeVariedPatterns() public view {
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

    /// @dev Test extendUntilEnd() edge cases
    function testExtendUntilEndEdgeCases() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Test extending from empty tree (nextLeafIndex == 0)
        merkleMemory._nextLeafIndex = 0;
        merkleMemory._sides = new bytes32[](1);
        merkleMemory._zeros = new bytes32[](1);
        merkleMemory._sides[0] = ZERO;
        merkleMemory._zeros[0] = ZERO;
        merkleMemory._sidesLengthMemory = 1;
        merkleMemory._zerosLengthMemory = 1;

        // Extend the tree to a larger depth
        bytes32[] memory newSides = new bytes32[](5);
        bytes32[] memory newZeros = new bytes32[](5);
        for (uint256 i = 0; i < 1; i++) {
            newSides[i] = merkleMemory._sides[i];
            newZeros[i] = merkleMemory._zeros[i];
        }
        merkleMemory._sides = newSides;
        merkleMemory._zeros = newZeros;

        // This should extend the tree properly
        DynamicIncrementalMerkleMemory.extendUntilEnd(merkleMemory);

        assertEq(merkleMemory._sidesLengthMemory, 5);
        assertEq(merkleMemory._zerosLengthMemory, 5);
        assertTrue(merkleMemory._sides[0] == ZERO); // Should set _sides[0] = currentZero when _nextLeafIndex == 0
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

        assertEq(regularRoot, lazyRoot);

        // Lazy should be significantly more efficient
        assertLt(gasUsedLazy, gasUsedRegular, "Lazy should use less gas");

        emit log_named_uint("Regular gas used", gasUsedRegular);
        emit log_named_uint("Lazy gas used", gasUsedLazy);
        emit log_named_uint("Gas savings", gasUsedRegular - gasUsedLazy);

        // Verify significant savings (should be >40%)
        uint256 savingsPercent = ((gasUsedRegular - gasUsedLazy) * 100) / gasUsedRegular;
        assertGt(savingsPercent, 40, "Should achieve significant gas savings");
    }

    /// @dev Test createTree() function initialization
    function testCreateTreeInitialization() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory;

        DynamicIncrementalMerkleMemory.createTree(merkleMemory, 10);

        assertEq(merkleMemory._sides.length, 10);
        assertEq(merkleMemory._zeros.length, 10);
        assertEq(merkleMemory._sidesLengthMemory, 0);
        assertEq(merkleMemory._zerosLengthMemory, 0);
        assertEq(merkleMemory._nextLeafIndex, 0);
        assertFalse(merkleMemory._needsRootRecalculation);
        assertEq(merkleMemory._lastLeafValue, bytes32(0));
    }

    /// @dev Test various extendUntilEnd() scenarios for memory tree
    function testExtendUntilEndScenarios() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        // Setup initial state with some elements
        merkleMemory.push(bytes32(uint256(1)));
        merkleMemory.push(bytes32(uint256(2)));

        // Manually extend the arrays to test extending behavior
        bytes32[] memory newSides = new bytes32[](8);
        bytes32[] memory newZeros = new bytes32[](8);

        for (uint256 i = 0; i < merkleMemory._sidesLengthMemory && i < newSides.length; i++) {
            newSides[i] = merkleMemory._sides[i];
        }
        for (uint256 i = 0; i < merkleMemory._zerosLengthMemory && i < newZeros.length; i++) {
            newZeros[i] = merkleMemory._zeros[i];
        }

        merkleMemory._sides = newSides;
        merkleMemory._zeros = newZeros;

        DynamicIncrementalMerkleMemory.extendUntilEnd(merkleMemory);

        assertEq(merkleMemory._sidesLengthMemory, 8);
        assertEq(merkleMemory._zerosLengthMemory, 8);
        assertFalse(merkleMemory._needsRootRecalculation);

        // extendUntilEnd pads the 2-leaf root with zero subtrees up to 8 levels.
        bytes32 expectedRoot = Merkle.efficientHash(bytes32(uint256(1)), bytes32(uint256(2)));
        bytes32 zero = Merkle.efficientHash(ZERO, ZERO);
        for (uint256 i = 2; i < 8; ++i) {
            expectedRoot = Merkle.efficientHash(expectedRoot, zero);
            zero = Merkle.efficientHash(zero, zero);
        }
        assertEq(merkleMemory.root(), expectedRoot);
    }

    function testRecalculateRootAfterResetWithPendingLazyPush() public pure {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();
        merkleMemory.pushLazy(bytes32(uint256(1)));
        merkleMemory.pushLazy(bytes32(uint256(2)));
        merkleMemory.pushLazy(bytes32(uint256(3)));
        assertTrue(merkleMemory._needsRootRecalculation);

        // setup() resets the leaf count but not the pending-recalculation flag.
        merkleMemory.setup(ZERO);
        assertTrue(merkleMemory._needsRootRecalculation);
        assertEq(merkleMemory.root(), bytes32(0));
    }

    /// @dev Test comprehensive storage vs memory equivalence
    function testStorageMemoryEquivalenceComprehensive() public {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory merkleMemory = setUpMemory();

        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 1; // Single element
        testSizes[1] = 7; // Odd number
        testSizes[2] = 16; // Power of 2
        testSizes[3] = 33; // After expansion

        for (uint256 t = 0; t < testSizes.length; t++) {
            merkleTest = new IncrementalMerkleTest(ZERO);
            merkleMemory = setUpMemory();

            for (uint256 i = 0; i < testSizes[t]; i++) {
                bytes32 value = keccak256(abi.encodePacked("test", t, "elem", i));
                merkleTest.push(value);
                merkleMemory.push(value);
            }

            assertEq(merkleTest.root(), merkleMemory.root(), "Root mismatch in comprehensive test");
            assertEq(merkleTest.height(), merkleMemory.height(), "Height mismatch in comprehensive test");
            assertEq(merkleTest.index(), merkleMemory.index(), "Index mismatch in comprehensive test");
        }
    }
}
