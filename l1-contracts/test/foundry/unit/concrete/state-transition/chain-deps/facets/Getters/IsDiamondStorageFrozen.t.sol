// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract IsDiamondStorageFrozenTest is GettersFacetTest {
    function test() public {
        gettersFacetWrapper.util_setIsDiamondStorageFrozen(true);

        bool received = gettersFacet.isDiamondStorageFrozen();

        assertTrue(received, "Received DiamondStorageFrozen is incorrect");
    }
}
