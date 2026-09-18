// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract GetBaseTokenTest is GettersFacetTest {
    function test() public {
        bytes32 expected = bytes32(uint256(uint160(makeAddr("baseToken"))));
        gettersFacetWrapper.util_setBaseToken(expected);

        bytes32 received = gettersFacet.getBaseTokenAssetId();

        assertEq(expected, received, "BaseToken address is incorrect");
    }

    function test_getBaseToken() public {
        address expectedBaseToken = makeAddr("actualBaseToken");
        address bridgehub = makeAddr("bridgehub");
        uint256 chainId = 123;

        gettersFacetWrapper.util_setBridgehub(bridgehub);
        gettersFacetWrapper.util_setChainId(chainId);

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector, chainId),
            abi.encode(expectedBaseToken)
        );

        address received = gettersFacet.getBaseToken();

        assertEq(expectedBaseToken, received, "Base token address is incorrect");
    }
}
