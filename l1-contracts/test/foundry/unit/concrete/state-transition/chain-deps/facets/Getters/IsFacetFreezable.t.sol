// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract IsFacetFreezableTest is GettersFacetTest {
    function test_noSelectors() public {
        address facet = makeAddr("facet");
        bool received = gettersFacet.isFacetFreezable(facet);

        assertFalse(received, "Received isFacetFreezable is incorrect");
    }

    function test() public {
        address facet = makeAddr("facet");
        gettersFacetWrapper.util_setIsFacetFreezable(facet, true);

        bool received = gettersFacet.isFacetFreezable(facet);

        assertTrue(received, "Received isFacetFreezable is incorrect");
    }
}
