// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UncheckedMath} from "contracts/common/libraries/UncheckedMath.sol";

/// @notice Unit tests for UncheckedMath library
contract UncheckedMathTest is Test {
    // ============ uncheckedInc Tests ============

    function test_uncheckedInc_basicValue() public pure {
        uint256 result = UncheckedMath.uncheckedInc(0);
        assertEq(result, 1);
    }

    function test_uncheckedInc_normalValue() public pure {
        uint256 result = UncheckedMath.uncheckedInc(100);
        assertEq(result, 101);
    }

    function test_uncheckedInc_overflow() public pure {
        // This should wrap around without reverting
        uint256 result = UncheckedMath.uncheckedInc(type(uint256).max);
        assertEq(result, 0);
    }

    function testFuzz_uncheckedInc(uint256 value) public pure {
        vm.assume(value < type(uint256).max);
        uint256 result = UncheckedMath.uncheckedInc(value);
        assertEq(result, value + 1);
    }

    // ============ uncheckedAdd Tests ============

    function test_uncheckedAdd_basicValues() public pure {
        uint256 result = UncheckedMath.uncheckedAdd(1, 2);
        assertEq(result, 3);
    }

    function test_uncheckedAdd_zeroValues() public pure {
        uint256 result = UncheckedMath.uncheckedAdd(0, 0);
        assertEq(result, 0);
    }

    function test_uncheckedAdd_oneZero() public pure {
        uint256 result = UncheckedMath.uncheckedAdd(100, 0);
        assertEq(result, 100);

        result = UncheckedMath.uncheckedAdd(0, 200);
        assertEq(result, 200);
    }

    function test_uncheckedAdd_largeValues() public pure {
        uint256 a = type(uint128).max;
        uint256 b = type(uint128).max;
        uint256 result = UncheckedMath.uncheckedAdd(a, b);
        assertEq(result, a + b);
    }

    function test_uncheckedAdd_overflow() public pure {
        // This should wrap around without reverting
        uint256 result = UncheckedMath.uncheckedAdd(type(uint256).max, 1);
        assertEq(result, 0);
    }

    function test_uncheckedAdd_overflowLarger() public pure {
        // This should wrap around without reverting
        uint256 result = UncheckedMath.uncheckedAdd(type(uint256).max, 100);
        assertEq(result, 99);
    }

    function testFuzz_uncheckedAdd(uint256 a, uint256 b) public pure {
        // Don't check overflow cases - just verify it doesn't revert
        uint256 result = UncheckedMath.uncheckedAdd(a, b);

        // If no overflow, result should equal a + b
        unchecked {
            assertEq(result, a + b);
        }
    }

    function testFuzz_uncheckedAdd_nonOverflow(uint128 a, uint128 b) public pure {
        // Using uint128 inputs guarantees no overflow when added
        uint256 result = UncheckedMath.uncheckedAdd(uint256(a), uint256(b));
        assertEq(result, uint256(a) + uint256(b));
    }
}
