// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UncheckedMath} from "contracts/common/libraries/UncheckedMath.sol";

/// @notice Unit tests for UncheckedMath library
contract UncheckedMathLibraryTest is Test {
    // ============ uncheckedInc Tests ============

    function test_uncheckedInc_overflow() public pure {
        uint256 result = UncheckedMath.uncheckedInc(type(uint256).max);
        assertEq(result, 0);
    }

    function testFuzz_uncheckedInc(uint256 _value) public pure {
        vm.assume(_value < type(uint256).max);
        uint256 result = UncheckedMath.uncheckedInc(_value);
        assertEq(result, _value + 1);
    }

    // ============ uncheckedAdd Tests ============

    function test_uncheckedAdd_overflow() public pure {
        uint256 result = UncheckedMath.uncheckedAdd(type(uint256).max, 1);
        assertEq(result, 0);
    }

    function testFuzz_uncheckedAdd(uint256 _a, uint256 _b) public pure {
        uint256 result = UncheckedMath.uncheckedAdd(_a, _b);

        unchecked {
            assertEq(result, _a + _b);
        }
    }
}
