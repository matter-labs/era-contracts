// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract FacetAddressTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("facetAddress");
        bytes4 selector = bytes4("4321");

        gettersFacetWrapper.util_setFacetAddress(selector, expected);

        address received = gettersFacet.facetAddress(selector);

        assertEq(expected, received, "Received Facet Address is incorrect");
    }
}
