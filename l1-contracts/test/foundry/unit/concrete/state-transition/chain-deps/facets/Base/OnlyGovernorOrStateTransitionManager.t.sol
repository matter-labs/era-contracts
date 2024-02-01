// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER} from "./_Base_Shared.t.sol";

contract OnlyGovernorOrStateTransitionManagerTest is ZkSyncStateTransitionBaseTest {
    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonGovernor);
        testBaseFacet.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTranstionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByGovernor() public {
        address governor = utilsFacet.util_getGovernor();

        vm.startPrank(governor);
        testBaseFacet.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }
}
