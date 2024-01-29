// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetPendingGovernorTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("pendingGovernor");
        gettersFacetWrapper.util_setPendingGovernor(expected);

        address received = gettersFacet.getPendingGovernor();

        assertEq(expected, received, "Pending governor address is incorrect");
    }
}
