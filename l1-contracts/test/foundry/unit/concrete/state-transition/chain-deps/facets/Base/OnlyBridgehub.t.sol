// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_BRIDGEHUB} from "./_Base_Shared.t.sol";

contract OnlyBridgehubTest is ZkSyncStateTransitionBaseTest {
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
