// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetFirstUnprocessedPriorityTxTest is GettersFacetTest {
    function test() public {
        uint256 expected = 7865;
        gettersFacetWrapper.util_setFirstUnprocessedPriorityTx(expected);

        uint256 received = gettersFacet.getFirstUnprocessedPriorityTx();

        assertEq(expected, received, "First unprocessed priority tx is incorrect");
    }
}
