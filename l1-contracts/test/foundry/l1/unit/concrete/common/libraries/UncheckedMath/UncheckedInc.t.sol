// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UncheckedMathSharedTest} from "./_UncheckedMath_Shared.t.sol";

contract UncheckedIncTest is UncheckedMathSharedTest {
    function test_Inc() public {
        uint256 a = 1234;
        uint256 c = uncheckedMath.uncheckedInc(a);
        assertEq(c, 1235);
    }

    function test_IncWithOverflow() public {
        uint256 a = type(uint256).max;

        // uncheckedInc does not fail
        uint256 c = uncheckedMath.uncheckedInc(a);
        assertEq(c, 0);

        // regular addition fails with overflow
        vm.expectRevert();
        a + 1;
    }
}
