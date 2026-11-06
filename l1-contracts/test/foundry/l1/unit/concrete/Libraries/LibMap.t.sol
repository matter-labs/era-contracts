// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LibMap} from "contracts/state-transition/libraries/LibMap.sol";

/// @notice Unit tests for LibMap library
contract LibMapTest is Test {
    using LibMap for LibMap.Uint32Map;

    LibMap.Uint32Map internal map;

    // ============ get Tests ============

    function test_get_returnsZeroForUnset() public view {
        uint32 value = map.get(0);
        assertEq(value, 0);

        value = map.get(100);
        assertEq(value, 0);
    }

    function test_get_returnsStoredValue() public {
        map.set(5, 12345);

        uint32 value = map.get(5);
        assertEq(value, 12345);
    }

    // ============ set Tests ============

    function test_set_basicValue() public {
        map.set(0, 42);

        uint32 value = map.get(0);
        assertEq(value, 42);
    }

    function test_set_maxValue() public {
        map.set(0, type(uint32).max);

        uint32 value = map.get(0);
        assertEq(value, type(uint32).max);
    }

    function test_set_multipleIndices() public {
        map.set(0, 100);
        map.set(1, 200);
        map.set(2, 300);

        assertEq(map.get(0), 100);
        assertEq(map.get(1), 200);
        assertEq(map.get(2), 300);
    }

    function test_set_overwriteValue() public {
        map.set(5, 100);
        assertEq(map.get(5), 100);

        map.set(5, 200);
        assertEq(map.get(5), 200);
    }

    function test_set_overwriteWithZero() public {
        map.set(5, 100);
        assertEq(map.get(5), 100);

        map.set(5, 0);
        assertEq(map.get(5), 0);
    }

    // ============ Packing Tests (8 values per slot) ============

    function test_packing_eightValuesInOneSlot() public {
        // Each storage slot holds 8 uint32 values
        // Indices 0-7 go into one slot
        for (uint256 i = 0; i < 8; i++) {
            map.set(i, uint32(100 + i));
        }

        for (uint256 i = 0; i < 8; i++) {
            assertEq(map.get(i), uint32(100 + i));
        }
    }

    function test_packing_crossSlotBoundary() public {
        // Index 7 is last in first slot
        // Index 8 is first in second slot
        map.set(7, 1111);
        map.set(8, 2222);

        assertEq(map.get(7), 1111);
        assertEq(map.get(8), 2222);
    }

    function test_packing_updateDoesNotAffectNeighbors() public {
        // Set multiple values in same slot
        map.set(0, 100);
        map.set(1, 200);
        map.set(2, 300);

        // Update middle value
        map.set(1, 999);

        // Neighbors should be unchanged
        assertEq(map.get(0), 100);
        assertEq(map.get(1), 999);
        assertEq(map.get(2), 300);
    }

    function test_packing_largeIndices() public {
        uint256 largeIndex = 1000000;
        map.set(largeIndex, 12345);

        assertEq(map.get(largeIndex), 12345);
        // Adjacent indices should still be zero
        assertEq(map.get(largeIndex - 1), 0);
        assertEq(map.get(largeIndex + 1), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_setAndGet(uint256 index, uint32 value) public {
        vm.assume(index < type(uint128).max);

        map.set(index, value);
        assertEq(map.get(index), value);
    }

    function testFuzz_multipleSetAndGet(uint256[8] memory indices, uint32[8] memory values) public {
        // Set all values
        for (uint256 i = 0; i < 8; i++) {
            vm.assume(indices[i] < type(uint64).max);
            map.set(indices[i], values[i]);
        }

        // Verify last write wins for duplicate indices
        for (uint256 i = 0; i < 8; i++) {
            // Find the last value written to this index
            uint32 expectedValue = values[i];
            for (uint256 j = i + 1; j < 8; j++) {
                if (indices[j] == indices[i]) {
                    expectedValue = values[j];
                }
            }
            assertEq(map.get(indices[i]), expectedValue);
        }
    }

    function testFuzz_overwrite(uint256 index, uint32 value1, uint32 value2) public {
        vm.assume(index < type(uint128).max);

        map.set(index, value1);
        assertEq(map.get(index), value1);

        map.set(index, value2);
        assertEq(map.get(index), value2);
    }

    // ============ Edge Cases ============

    function test_zeroIndex() public {
        map.set(0, 42);
        assertEq(map.get(0), 42);
    }

    function test_consecutiveIndices() public {
        for (uint256 i = 0; i < 100; i++) {
            map.set(i, uint32(i * 10));
        }

        for (uint256 i = 0; i < 100; i++) {
            assertEq(map.get(i), uint32(i * 10));
        }
    }

    function test_sparseIndices() public {
        map.set(0, 100);
        map.set(1000, 200);
        map.set(1000000, 300);

        assertEq(map.get(0), 100);
        assertEq(map.get(1000), 200);
        assertEq(map.get(1000000), 300);

        // Indices in between should be zero
        assertEq(map.get(500), 0);
        assertEq(map.get(500000), 0);
    }

    function test_allPositionsInSlot() public {
        // Test all 8 positions within a single storage slot
        uint256 baseIndex = 24; // Start at slot 3 (24/8 = 3)

        for (uint256 i = 0; i < 8; i++) {
            map.set(baseIndex + i, uint32(1000 + i));
        }

        for (uint256 i = 0; i < 8; i++) {
            assertEq(map.get(baseIndex + i), uint32(1000 + i));
        }
    }
}
