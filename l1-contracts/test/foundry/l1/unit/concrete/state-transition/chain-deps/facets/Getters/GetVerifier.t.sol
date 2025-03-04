// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetVerifierTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("verifier");
        gettersFacetWrapper.util_setVerifier(expected);

        address received = gettersFacet.getVerifier();

        assertEq(expected, received, "Verifier address is incorrect");
    }
}
