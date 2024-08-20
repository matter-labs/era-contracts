// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetBaseTokenTest is GettersFacetTest {
    function test() public {
        bytes32 expected = bytes32(uint256(uint160(makeAddr("baseToken"))));
        gettersFacetWrapper.util_setBaseToken(expected);

        bytes32 received = gettersFacet.getBaseTokenAssetId();

        assertEq(expected, received, "BaseToken address is incorrect");
    }
}
