// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract GetBaseTokenTest is GettersFacetTest {
    function test_getter() public {
        bytes32 expected = bytes32(uint256(uint160(makeAddr("baseToken"))));
        gettersFacetWrapper.util_setBaseToken(expected);

        bytes32 received = gettersFacet.getBaseTokenAssetId();

        assertEq(expected, received, "BaseToken address is incorrect");
    }

    function test_getBaseToken() public {
        // In integration context, use the real Bridgehub and chain to verify getBaseToken.
        // The real Bridgehub stores the base token for each chain during deployment.
        address received = gettersFacet.getBaseToken();
        // The integration deployment uses ETH as the base token for test chains
        assertTrue(received != address(0), "Base token address should be non-zero");
    }
}
