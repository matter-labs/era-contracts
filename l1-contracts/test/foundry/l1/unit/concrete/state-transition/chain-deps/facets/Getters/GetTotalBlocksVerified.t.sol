// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetTotalBlocksVerifiedTest is GettersFacetTest {
    function test() public {
        uint256 expected = 123456787654345789;
        gettersFacetWrapper.util_setTotalBatchesVerified(expected);

        uint256 received = legacyGettersFacet.getTotalBlocksVerified();

        assertEq(expected, received, "Total batches verified is incorrect");
    }
}
