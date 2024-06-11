// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract L2LogsRootHashTest is GettersFacetTest {
    function test() public {
        uint256 batchNumber = 42;
        bytes32 expected = keccak256("L2 Logs Root Hash");
        gettersFacetWrapper.util_setL2LogsRootHash(batchNumber, expected);

        bytes32 received = gettersFacet.l2LogsRootHash(batchNumber);

        assertEq(expected, received, "L2 Logs Root Hash is incorrect");
    }
}
