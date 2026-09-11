// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetZKsyncOSTest is GettersFacetTest {
    function test_returnsStoredFalse() public {
        gettersFacetWrapper.util_setZKsyncOS(false);

        assertFalse(gettersFacet.getZKsyncOS());
    }

    function test_returnsStoredTrue() public {
        gettersFacetWrapper.util_setZKsyncOS(true);

        assertTrue(gettersFacet.getZKsyncOS());
    }
}
