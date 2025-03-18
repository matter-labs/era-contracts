// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetProtocolVersionTest is GettersFacetTest {
    function test() public {
        uint256 expected = 765456;
        gettersFacetWrapper.util_setProtocolVersion(expected);

        uint256 received = gettersFacet.getProtocolVersion();

        assertEq(expected, received, "Protocol version is incorrect");
    }
}
