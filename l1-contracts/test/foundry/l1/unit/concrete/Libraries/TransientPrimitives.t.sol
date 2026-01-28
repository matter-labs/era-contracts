// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransientPrimitivesLib} from "contracts/common/libraries/TransientPrimitives/TransientPrimitives.sol";

/// @notice Unit tests for TransientPrimitives library
contract TransientPrimitivesTest is Test {
    // ============ set and getUint256 Tests ============

    function test_setAndGet_basicValue() public {
        uint256 slot = 0;
        uint256 value = 42;

        TransientPrimitivesLib.set(slot, value);
        uint256 result = TransientPrimitivesLib.getUint256(slot);

        assertEq(result, value);
    }

    function test_setAndGet_zeroValue() public {
        uint256 slot = 1;
        uint256 value = 0;

        TransientPrimitivesLib.set(slot, value);
        uint256 result = TransientPrimitivesLib.getUint256(slot);

        assertEq(result, value);
    }

    function test_setAndGet_maxValue() public {
        uint256 slot = 2;
        uint256 value = type(uint256).max;

        TransientPrimitivesLib.set(slot, value);
        uint256 result = TransientPrimitivesLib.getUint256(slot);

        assertEq(result, value);
    }

    function test_setAndGet_multipleSlots() public {
        TransientPrimitivesLib.set(0, 100);
        TransientPrimitivesLib.set(1, 200);
        TransientPrimitivesLib.set(2, 300);

        assertEq(TransientPrimitivesLib.getUint256(0), 100);
        assertEq(TransientPrimitivesLib.getUint256(1), 200);
        assertEq(TransientPrimitivesLib.getUint256(2), 300);
    }

    function test_setAndGet_overwriteValue() public {
        uint256 slot = 5;

        TransientPrimitivesLib.set(slot, 100);
        assertEq(TransientPrimitivesLib.getUint256(slot), 100);

        TransientPrimitivesLib.set(slot, 200);
        assertEq(TransientPrimitivesLib.getUint256(slot), 200);
    }

    function test_get_unsetSlotReturnsZero() public view {
        uint256 result = TransientPrimitivesLib.getUint256(999);
        assertEq(result, 0);
    }

    function testFuzz_setAndGet(uint256 slot, uint256 value) public {
        TransientPrimitivesLib.set(slot, value);
        uint256 result = TransientPrimitivesLib.getUint256(slot);
        assertEq(result, value);
    }

    function testFuzz_setAndGet_multipleSlots(uint256[5] memory slots, uint256[5] memory values) public {
        // Set all values
        for (uint256 i = 0; i < 5; i++) {
            TransientPrimitivesLib.set(slots[i], values[i]);
        }

        // Verify - note that later writes to the same slot will overwrite earlier ones
        for (uint256 i = 0; i < 5; i++) {
            // Find the last value written to this slot
            uint256 expectedValue = values[i];
            for (uint256 j = i + 1; j < 5; j++) {
                if (slots[j] == slots[i]) {
                    expectedValue = values[j];
                }
            }
            assertEq(TransientPrimitivesLib.getUint256(slots[i]), expectedValue);
        }
    }

    function test_transientStorage_isPerTransaction() public {
        uint256 slot = 10;
        uint256 value = 12345;

        TransientPrimitivesLib.set(slot, value);

        // Within the same transaction, value should persist
        assertEq(TransientPrimitivesLib.getUint256(slot), value);
    }

    function test_largeSlotNumbers() public {
        uint256 largeSlot = type(uint256).max - 1;
        uint256 value = 999;

        TransientPrimitivesLib.set(largeSlot, value);
        uint256 result = TransientPrimitivesLib.getUint256(largeSlot);

        assertEq(result, value);
    }

    function test_adjacentSlots_areIndependent() public {
        TransientPrimitivesLib.set(100, 1);
        TransientPrimitivesLib.set(101, 2);
        TransientPrimitivesLib.set(102, 3);

        assertEq(TransientPrimitivesLib.getUint256(100), 1);
        assertEq(TransientPrimitivesLib.getUint256(101), 2);
        assertEq(TransientPrimitivesLib.getUint256(102), 3);

        // Update middle slot
        TransientPrimitivesLib.set(101, 999);

        // Other slots should be unchanged
        assertEq(TransientPrimitivesLib.getUint256(100), 1);
        assertEq(TransientPrimitivesLib.getUint256(101), 999);
        assertEq(TransientPrimitivesLib.getUint256(102), 3);
    }
}
