// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetChainTypeManagerTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("chainTypeManager");
        gettersFacetWrapper.util_setChainTypeManager(expected);

        address received = gettersFacet.getChainTypeManager();

        assertEq(expected, received, "ChainTypeManager address is incorrect");
    }
}
