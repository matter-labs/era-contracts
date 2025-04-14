// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetPriorityTxMaxGasLimitTest is GettersFacetTest {
    function test() public {
        uint256 expected = 3456789;
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(expected);

        uint256 received = gettersFacet.getPriorityTxMaxGasLimit();

        assertEq(expected, received, "Priority Tx Max Gas Limit is incorrect");
    }
}
