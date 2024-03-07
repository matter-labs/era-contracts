// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER} from "./_Base_Shared.t.sol";

contract OnlyAdminOrStateTransitionManagerTest is ZkSyncStateTransitionBaseTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.expectRevert(ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonAdmin);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTranstionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }
}
