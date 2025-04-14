// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2SystemContractsUpgradeBatchNumberTest is GettersFacetTest {
    function test() public {
        uint256 expected = 56432;
        gettersFacetWrapper.util_setL2SystemContractsUpgradeBatchNumber(expected);

        uint256 received = gettersFacet.getL2SystemContractsUpgradeBatchNumber();

        assertEq(expected, received, "L2 System Contracts Upgrade Batch Number is incorrect");
    }
}
