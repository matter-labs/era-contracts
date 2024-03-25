// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PriorityOperation} from "contracts/state-transition/libraries/PriorityQueue.sol";

contract GetPriorityQueueFrontOperationTest is GettersFacetTest {
    function test_revertWhen_queueIsEmpty() public {
        vm.expectRevert(bytes.concat("D"));
        gettersFacet.priorityQueueFrontOperation();
    }

    function test() public {
        PriorityOperation memory expected = PriorityOperation({
            canonicalTxHash: bytes32(uint256(1)),
            expirationTimestamp: uint64(2),
            layer2Tip: uint192(3)
        });

        gettersFacetWrapper.util_setPriorityQueueFrontOperation(expected);

        PriorityOperation memory received = gettersFacet.priorityQueueFrontOperation();

        bytes32 expectedHash = keccak256(abi.encode(expected));
        bytes32 receivedHash = keccak256(abi.encode(received));
        assertEq(expectedHash, receivedHash, "Priority queue front operation is incorrect");
    }
}
