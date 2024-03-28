// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UncheckedMathSharedTest} from "./_UncheckedMath_Shared.t.sol";

contract UncheckedAddTest is UncheckedMathSharedTest {
    function test_Add() public {
        uint256 a = 1234;
        uint256 b = 4321;
        uint256 c = uncheckedMath.uncheckedAdd(a, b);
        assertEq(c, 5555);
    }

    function test_AddWithOverflow() public {
        uint256 a = type(uint256).max;
        uint256 b = 1;

        // uncheckedAdd does not fail
        uint256 c = uncheckedMath.uncheckedAdd(a, b);
        assertEq(c, 0);

        // regular addition fails with overflow
        vm.expectRevert();
        a + b;
    }
}
