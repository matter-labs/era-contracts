// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_STATE_TRANSITION_MANAGER} from "./_Base_Shared.t.sol";

contract OnlyStateTransitionManagerTest is ZkSyncStateTransitionBaseTest {
    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithOnlyStateTransitionManagerModifier();
    }

    function test_successfulCall() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithOnlyStateTransitionManagerModifier();
    }
}
