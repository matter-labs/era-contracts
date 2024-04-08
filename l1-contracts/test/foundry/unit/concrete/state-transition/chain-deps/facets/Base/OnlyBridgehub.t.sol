// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest, ERROR_ONLY_BRIDGEHUB} from "./_Base_Shared.t.sol";

contract OnlyBridgehubTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonBridgehub() public {
        address nonBridgehub = makeAddr("nonBridgehub");

        vm.expectRevert(ERROR_ONLY_BRIDGEHUB);

        vm.startPrank(nonBridgehub);
        testBaseFacet.functionWithOnlyBridgehubModifier();
    }

    function test_successfulCall() public {
        address bridgehub = utilsFacet.util_getBridgehub();

        vm.startPrank(bridgehub);
        testBaseFacet.functionWithOnlyBridgehubModifier();
    }
}
