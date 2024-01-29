// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER} from "./_ZkSyncStateTransitionBase_Shared.t.sol";

contract OnlyGovernorOrStateTransitionManagerTest is ZkSyncStateTransitionBaseTest {
    function setUp() public override {
        super.setUp();
        baseFacetWrapper.util_setGovernor(makeAddr("governor"));
        baseFacetWrapper.util_setStateTransitionManager(makeAddr("stateTransitionManager"));
    }

    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonGovernor);
        baseFacetWrapper.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTranstionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        baseFacetWrapper.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByGovernor() public {
        address governor = baseFacetWrapper.util_getGovernor();

        vm.startPrank(governor);
        baseFacetWrapper.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = baseFacetWrapper.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        baseFacetWrapper.functionWithOnlyGovernorOrStateTransitionManagerModifier();
    }
}
