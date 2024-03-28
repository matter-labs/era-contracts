// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract IsFunctionFreezableTest is GettersFacetTest {
    function test_revertWhen_facetAddressIzZero() public {
        bytes4 selector = bytes4(keccak256("asdfghfjtyhrewd"));
        gettersFacetWrapper.util_setIsFunctionFreezable(selector, true);

        gettersFacetWrapper.util_setFacetAddress(selector, address(0));

        vm.expectRevert(bytes.concat("g2"));

        gettersFacet.isFunctionFreezable(selector);
    }

    function test() public {
        bytes4 selector = bytes4(keccak256("asdfghfjtyhrewd"));
        gettersFacetWrapper.util_setFacetAddress(selector, makeAddr("nonZeroAddress"));
        gettersFacetWrapper.util_setIsFunctionFreezable(selector, true);

        bool received = gettersFacet.isFunctionFreezable(selector);

        assertTrue(received, "Received isFunctionFreezable is incorrect");
    }
}
