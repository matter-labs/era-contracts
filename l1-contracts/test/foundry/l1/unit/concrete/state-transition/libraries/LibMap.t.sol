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

    function test_set_storesMaxUint32() public {
        testMap.set(0, type(uint32).max);
        assertEq(testMap.get(0), type(uint32).max);
    }

    function test_set_storesZero() public {
        testMap.set(0, 12345);
        testMap.set(0, 0);
        assertEq(testMap.get(0), 0);
    }

    function test_set_adjacentSlotBoundary() public {
        // Index 7 is last in slot 0, index 8 is first in slot 1
        testMap.set(7, 777);
        testMap.set(8, 888);

        assertEq(testMap.get(7), 777);
        assertEq(testMap.get(8), 888);
    }

    // ============ Fuzz Tests ============

    function testFuzz_setAndGet(uint256 _index, uint32 _value) public {
        testMap.set(_index, _value);
        assertEq(testMap.get(_index), _value);
    }

    function testFuzz_multipleSetsSameIndex(uint256 _index, uint32 _value1, uint32 _value2) public {
        testMap.set(_index, _value1);
        assertEq(testMap.get(_index), _value1);

        testMap.set(_index, _value2);
        assertEq(testMap.get(_index), _value2);
    }

    function testFuzz_setDoesNotAffectOtherSlots(
        uint256 _index1,
        uint256 _index2,
        uint32 _value1,
        uint32 _value2
    ) public {
        vm.assume(_index1 / 8 != _index2 / 8);

        testMap.set(_index1, _value1);
        testMap.set(_index2, _value2);

        assertEq(testMap.get(_index1), _value1);
        assertEq(testMap.get(_index2), _value2);
    }

    function testFuzz_xorPropertyPreservesOtherValues(
        uint8 _slotOffset,
        uint32[8] memory _values,
        uint8 _updatePos,
        uint32 _newValue
    ) public {
        _updatePos = _updatePos % 8;
        uint256 baseIndex = uint256(_slotOffset) * 8;

        for (uint256 i = 0; i < 8; i++) {
            testMap.set(baseIndex + i, _values[i]);
        }

        testMap.set(baseIndex + _updatePos, _newValue);

        for (uint256 i = 0; i < 8; i++) {
            if (i == _updatePos) {
                assertEq(testMap.get(baseIndex + i), _newValue);
            } else {
                assertEq(testMap.get(baseIndex + i), _values[i]);
            }
        }
    }
}
