// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetPendingAdminTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("pendingAdmin");
        gettersFacetWrapper.util_setPendingAdmin(expected);

        address received = gettersFacet.getPendingAdmin();

        assertEq(expected, received, "Pending governor address is incorrect");
    }
}
