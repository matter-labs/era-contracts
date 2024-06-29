// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PriorityOperation} from "contracts/state-transition/libraries/PriorityQueue.sol";

contract GetPriorityQueueFrontOperationTest is GettersFacetTest {
    function test_empty() public {
        PriorityOperation memory received = gettersFacet.priorityQueueFrontOperation();

        assertEq(received.canonicalTxHash, bytes32(0), "Priority queue front operation is incorrect");
        assertEq(received.layer2Tip, 0, "Priority queue front operation is incorrect");
        assertEq(received.expirationTimestamp, 0, "Priority queue front operation is incorrect");
    }
}
