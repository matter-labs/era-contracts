// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PriorityOperation} from "contracts/state-transition/libraries/PriorityQueue.sol";

contract GetPriorityQueueFrontOperationTest is GettersFacetTest {
    function test_empty() public {
        vm.expectRevert("PQFront for PriorityTree");
        PriorityOperation memory received = gettersFacet.priorityQueueFrontOperation();
    }
}
