// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest, ERROR_ONLY_BASE_TOKEN_BRIDGE} from "./_Base_Shared.t.sol";

contract OnlyBaseTokenBridge is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonBaseTokenBridge() public {
        address nonBaseTokenBridge = makeAddr("nonBaseTokenBridge");

        vm.expectRevert(ERROR_ONLY_BASE_TOKEN_BRIDGE);

        vm.startPrank(nonBaseTokenBridge);
        testBaseFacet.functionWithOnlyBaseTokenBridgeModifier();
    }

    function test_successfulCall() public {
        address baseTokenBridge = utilsFacet.util_getBaseTokenBridge();

        vm.startPrank(baseTokenBridge);
        testBaseFacet.functionWithOnlyBaseTokenBridgeModifier();
    }
}
