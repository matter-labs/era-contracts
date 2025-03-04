// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract FacetAddressesTest is GettersFacetTest {
    function test() public {
        address[] memory expected = new address[](2);
        expected[0] = address(1);
        expected[1] = address(2);

        gettersFacetWrapper.util_setFacetAddresses(expected);

        address[] memory received = gettersFacet.facetAddresses();

        bytes32 expectedHash = keccak256(abi.encode(expected));
        bytes32 receivedHash = keccak256(abi.encode(received));
        assertEq(expectedHash, receivedHash, "Received Facet Addresses are incorrect");
    }
}
