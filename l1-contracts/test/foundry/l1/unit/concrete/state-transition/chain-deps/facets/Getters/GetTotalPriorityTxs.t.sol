// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetTotalPriorityTxsTest is GettersFacetTest {
    function test() public {
        uint256 expected = 345678333335;
        gettersFacetWrapper.util_setTotalPriorityTxs(expected);

        uint256 received = gettersFacet.getTotalPriorityTxs();

        assertEq(expected, received, "Total priority txs is incorrect");
    }
}
