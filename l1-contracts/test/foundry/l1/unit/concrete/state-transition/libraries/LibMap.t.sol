// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LibMap} from "contracts/state-transition/libraries/LibMap.sol";

/// @notice Unit tests for LibMap library
contract LibMapTest is Test {
    using LibMap for LibMap.Uint32Map;

    LibMap.Uint32Map private testMap;

    // ============ get/set Tests ============

    function test_get_returnsZeroForUnsetIndex() public view {
        assertEq(testMap.get(0), 0);
        assertEq(testMap.get(1), 0);
        assertEq(testMap.get(100), 0);
    }

    function test_set_storesValueAtIndex() public {
        testMap.set(0, 12345);
        assertEq(testMap.get(0), 12345);
    }

    function test_set_storesMaxUint32() public {
        testMap.set(0, type(uint32).max);
        assertEq(testMap.get(0), type(uint32).max);
    }

    function test_set_storesZero() public {
        testMap.set(0, 12345);
        testMap.set(0, 0);
        assertEq(testMap.get(0), 0);
    }

    function test_set_overwritesExistingValue() public {
        testMap.set(0, 100);
        assertEq(testMap.get(0), 100);

        testMap.set(0, 200);
        assertEq(testMap.get(0), 200);
    }

    function test_set_multipleIndicesInSameSlot() public {
        // Indices 0-7 share the same storage slot
        testMap.set(0, 111);
        testMap.set(1, 222);
        testMap.set(2, 333);
        testMap.set(7, 888);

        assertEq(testMap.get(0), 111);
        assertEq(testMap.get(1), 222);
        assertEq(testMap.get(2), 333);
        assertEq(testMap.get(7), 888);
    }

    function test_set_doesNotAffectOtherIndicesInSlot() public {
        // Set values at indices 0-7 (same slot)
        for (uint256 i = 0; i < 8; i++) {
            testMap.set(i, uint32(i * 100));
        }

        // Update index 3, verify others unchanged
        testMap.set(3, 999);

        assertEq(testMap.get(0), 0);
        assertEq(testMap.get(1), 100);
        assertEq(testMap.get(2), 200);
        assertEq(testMap.get(3), 999);
        assertEq(testMap.get(4), 400);
        assertEq(testMap.get(5), 500);
        assertEq(testMap.get(6), 600);
        assertEq(testMap.get(7), 700);
    }

    function test_set_differentStorageSlots() public {
        // Index 0 is in slot 0, index 8 is in slot 1, index 16 is in slot 2
        testMap.set(0, 100);
        testMap.set(8, 200);
        testMap.set(16, 300);

        assertEq(testMap.get(0), 100);
        assertEq(testMap.get(8), 200);
        assertEq(testMap.get(16), 300);
    }

    function test_get_largeIndex() public {
        uint256 largeIndex = 1000000;
        testMap.set(largeIndex, 12345);
        assertEq(testMap.get(largeIndex), 12345);
    }

    function test_set_adjacentSlotBoundary() public {
        // Index 7 is last in slot 0, index 8 is first in slot 1
        testMap.set(7, 777);
        testMap.set(8, 888);

        assertEq(testMap.get(7), 777);
        assertEq(testMap.get(8), 888);
    }

    function test_set_allPositionsInSlot() public {
        // Fill all 8 positions in a single storage slot
        for (uint256 i = 0; i < 8; i++) {
            testMap.set(i, uint32(i + 1));
        }

        // Verify all positions
        for (uint256 i = 0; i < 8; i++) {
            assertEq(testMap.get(i), uint32(i + 1));
        }
    }

    function test_set_alternatingPatternInSlot() public {
        // Set alternating values
        testMap.set(0, type(uint32).max);
        testMap.set(1, 0);
        testMap.set(2, type(uint32).max);
        testMap.set(3, 0);

        assertEq(testMap.get(0), type(uint32).max);
        assertEq(testMap.get(1), 0);
        assertEq(testMap.get(2), type(uint32).max);
        assertEq(testMap.get(3), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_setAndGet(uint256 index, uint32 value) public {
        testMap.set(index, value);
        assertEq(testMap.get(index), value);
    }

    function testFuzz_multipleSetsSameIndex(uint256 index, uint32 value1, uint32 value2) public {
        testMap.set(index, value1);
        assertEq(testMap.get(index), value1);

        testMap.set(index, value2);
        assertEq(testMap.get(index), value2);
    }

    function testFuzz_setDoesNotAffectOtherSlots(uint256 index1, uint256 index2, uint32 value1, uint32 value2) public {
        // Ensure indices are in different slots
        vm.assume(index1 / 8 != index2 / 8);

        testMap.set(index1, value1);
        testMap.set(index2, value2);

        assertEq(testMap.get(index1), value1);
        assertEq(testMap.get(index2), value2);
    }

    function testFuzz_setInSameSlot(uint8 pos1, uint8 pos2, uint32 value1, uint32 value2) public {
        // Ensure positions are different and within slot (0-7)
        pos1 = pos1 % 8;
        pos2 = pos2 % 8;
        vm.assume(pos1 != pos2);

        testMap.set(pos1, value1);
        testMap.set(pos2, value2);

        assertEq(testMap.get(pos1), value1);
        assertEq(testMap.get(pos2), value2);
    }

    function testFuzz_xorPropertyPreservesOtherValues(
        uint8 slotOffset,
        uint32[8] memory values,
        uint8 updatePos,
        uint32 newValue
    ) public {
        updatePos = updatePos % 8;
        uint256 baseIndex = uint256(slotOffset) * 8;

        // Set initial values
        for (uint256 i = 0; i < 8; i++) {
            testMap.set(baseIndex + i, values[i]);
        }

        // Update one position
        testMap.set(baseIndex + updatePos, newValue);

        // Verify all values
        for (uint256 i = 0; i < 8; i++) {
            if (i == updatePos) {
                assertEq(testMap.get(baseIndex + i), newValue);
            } else {
                assertEq(testMap.get(baseIndex + i), values[i]);
            }
        }
    }
}
