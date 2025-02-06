// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AddressAliasHelperTest} from "contracts/dev-contracts/test/AddressAliasHelperTest.sol";

contract AddressAliasHelperSharedTest is Test {
    AddressAliasHelperTest addressAliasHelper;

    function setUp() public {
        addressAliasHelper = new AddressAliasHelperTest();
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
