// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetPriorityTreeStartIndexTest is GettersFacetTest {
    function test() public {
        uint256 expected = 42;
        gettersFacetWrapper.util_setPriorityTreeStartIndex(expected);

        uint256 received = gettersFacet.getPriorityTreeStartIndex();

        assertEq(expected, received, "Priority tree start index is incorrect");
    }

    function test_fuzz(uint256 _startIndex) public {
        gettersFacetWrapper.util_setPriorityTreeStartIndex(_startIndex);

        uint256 received = gettersFacet.getPriorityTreeStartIndex();

        assertEq(_startIndex, received, "Priority tree start index is incorrect");
    }
}
