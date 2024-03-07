// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetAdminrTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("admin");
        gettersFacetWrapper.util_setAdmin(expected);

        address received = gettersFacet.getAdmin();

        assertEq(expected, received, "Admin address is incorrect");
    }
}
