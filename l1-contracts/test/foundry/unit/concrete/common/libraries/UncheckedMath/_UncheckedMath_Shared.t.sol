// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {UncheckedMathTest} from "solpp/dev-contracts/test/UncheckedMathTest.sol";

contract UncheckedMathSharedTest is Test {
    UncheckedMathTest uncheckedMath;

    function setUp() public {
        uncheckedMath = new UncheckedMathTest();
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
