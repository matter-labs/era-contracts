// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2SystemContractsUpgradeBlockNumberTest is GettersFacetTest {
    function test() public {
        uint256 expected = 56432;
        gettersFacetWrapper.util_setL2SystemContractsUpgradeBatchNumber(expected);

        uint256 received = legacyGettersFacet.getL2SystemContractsUpgradeBlockNumber();

        assertEq(expected, received, "L2 System Contracts Upgrade Batch Number is incorrect");
    }
}
