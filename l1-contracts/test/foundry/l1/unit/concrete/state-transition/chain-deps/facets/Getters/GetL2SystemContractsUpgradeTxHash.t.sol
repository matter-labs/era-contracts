// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2SystemContractsUpgradeTxHashTest is GettersFacetTest {
    function test() public {
        bytes32 expected = keccak256("L2 System Contracts Upgrade Tx Hash");
        gettersFacetWrapper.util_setL2SystemContractsUpgradeTxHash(expected);

        bytes32 received = gettersFacet.getL2SystemContractsUpgradeTxHash();

        assertEq(expected, received, "L2 System Contracts Upgrade Tx Hash");
    }
}
