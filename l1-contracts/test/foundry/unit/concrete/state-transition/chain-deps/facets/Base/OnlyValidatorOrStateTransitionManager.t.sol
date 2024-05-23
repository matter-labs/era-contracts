// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest, ERROR_ONLY_VALIDATOR_OR_STATE_TRANSITION_MANAGER} from "./_Base_Shared.t.sol";

contract OnlyAdminOrStateTransitionManagerTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        vm.expectRevert(ERROR_ONLY_VALIDATOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonValidator);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_VALIDATOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address validator = makeAddr("validator");
        utilsFacet.util_setValidator(validator, true);

        vm.startPrank(validator);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }
}
