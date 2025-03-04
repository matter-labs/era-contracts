// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

contract FacetsTest is GettersFacetTest {
    function test() public {
        IGetters.Facet[] memory expected = new IGetters.Facet[](2);
        expected[0] = IGetters.Facet({addr: address(1), selectors: new bytes4[](1)});
        expected[0] = IGetters.Facet({addr: address(2), selectors: new bytes4[](1)});

        gettersFacetWrapper.util_setFacets(expected);

        IGetters.Facet[] memory received = gettersFacet.facets();

        bytes32 expectedHash = keccak256(abi.encode(expected));
        bytes32 receivedHash = keccak256(abi.encode(received));
        assertEq(expectedHash, receivedHash, "Received Facets are incorrect");
    }
}
