// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract FacetFunctionSelectorsTest is GettersFacetTest {
    function test() public {
        address facet = address(1);
        bytes4[] memory expected = new bytes4[](2);
        expected[0] = bytes4("1234");
        expected[1] = bytes4("4321");

        gettersFacetWrapper.util_setFacetFunctionSelectors(facet, expected);

        bytes4[] memory received = gettersFacet.facetFunctionSelectors(facet);

        bytes32 expectedHash = keccak256(abi.encode(expected));
        bytes32 receivedHash = keccak256(abi.encode(received));
        assertEq(expectedHash, receivedHash, "Received Facet Function Selectors are incorrect");
    }
}
