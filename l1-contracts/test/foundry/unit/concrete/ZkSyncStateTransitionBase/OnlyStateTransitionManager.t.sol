// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_STATE_TRANSITION_MANAGER} from "./_ZkSyncStateTransitionBase_Shared.t.sol";

contract OnlyStateTransitionManagerTest is ZkSyncStateTransitionBaseTest {
    function setUp() public override {
        super.setUp();
        baseFacetWrapper.util_setStateTransitionManager(makeAddr("stateTransitionManager"));
    }

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        baseFacetWrapper.functionWithOnlyStateTransitionManagerModifier();
    }

    function test_successfulCall() public {
        address stateTransitionManager = baseFacetWrapper.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        baseFacetWrapper.functionWithOnlyStateTransitionManagerModifier();
    }
}
