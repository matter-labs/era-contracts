// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetAdminTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("admin");
        gettersFacetWrapper.util_setAdmin(expected);

        address received = gettersFacet.getAdmin();

        assertEq(expected, received, "Admin address is incorrect");
    }
}
