// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {UncheckedMathTest} from "./_UncheckedMath_Shared.t.sol";
import {UncheckedMath} from "solpp/common/libraries/UncheckedMath.sol";

contract UncheckedIncTest is UncheckedMathTest {
    using UncheckedMath for uint256;

    function test_Inc() public {
        uint256 a = 1234;
        uint256 c = a.uncheckedInc();
        assertEq(c, 1235);
    }

    function test_IncWithOverflow() public {
        uint256 a = type(uint256).max;

        // uncheckedInc does not fail
        uint256 c = a.uncheckedInc();
        assertEq(c, 0);

        // regular addition fails with overflow
        vm.expectRevert();
        a + 1;
    }
}
