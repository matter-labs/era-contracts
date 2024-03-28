// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetPriorityQueueSizeTest is GettersFacetTest {
    function test() public {
        uint256 expected = 3456789;
        gettersFacetWrapper.util_setPriorityQueueSize(expected);

        uint256 received = gettersFacet.getPriorityQueueSize();

        assertEq(expected, received, "Priority queue size is incorrect");
    }
}
