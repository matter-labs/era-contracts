// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetTotalBlocksExecutedTest is GettersFacetTest {
    function test() public {
        uint256 expected = 4678097654;
        gettersFacetWrapper.util_setTotalBatchesExecuted(expected);

        uint256 received = legacyGettersFacet.getTotalBlocksExecuted();

        assertEq(expected, received, "Total batches executed is incorrect");
    }
}
