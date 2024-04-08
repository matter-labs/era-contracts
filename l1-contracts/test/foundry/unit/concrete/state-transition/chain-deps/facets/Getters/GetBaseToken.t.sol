// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetBaseTokenTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("baseToken");
        gettersFacetWrapper.util_setBaseToken(expected);

        address received = gettersFacet.getBaseToken();

        assertEq(expected, received, "BaseToken address is incorrect");
    }
}
