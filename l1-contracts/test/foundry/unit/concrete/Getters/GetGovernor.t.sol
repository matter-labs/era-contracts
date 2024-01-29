// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetGovernorTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("governor");
        gettersFacetWrapper.util_setGovernor(expected);

        address received = gettersFacet.getGovernor();

        assertEq(expected, received, "Governor address is incorrect");
    }
}
