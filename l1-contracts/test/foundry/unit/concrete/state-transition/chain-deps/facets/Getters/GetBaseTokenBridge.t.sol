// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetBaseTokenBridgeTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("baseTokenBride");
        gettersFacetWrapper.util_setBaseTokenBridge(expected);

        address received = gettersFacet.getBaseTokenBridge();

        assertEq(expected, received, "BaseTokenBridge address is incorrect");
    }
}
