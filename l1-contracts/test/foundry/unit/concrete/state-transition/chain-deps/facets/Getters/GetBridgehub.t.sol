// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetBridgehubTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("bridgehub");
        gettersFacetWrapper.util_setBridgehub(expected);

        address received = gettersFacet.getBridgehub();

        assertEq(expected, received, "Bridgehub address is incorrect");
    }
}
