// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetVerifierTest is GettersFacetTest {
    function test_getter() public {
        address expected = makeAddr("verifier");
        gettersFacetWrapper.util_setVerifierByAddress(expected);

        address received = gettersFacet.getVerifier();

        assertEq(expected, received, "Verifier address is incorrect");
    }
}
