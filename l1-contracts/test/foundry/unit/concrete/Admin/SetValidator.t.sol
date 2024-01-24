// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_STATE_TRANSITION_MANAGER} from "./_Admin_Shared.t.sol";

contract SetValidatorTest is AdminTest {
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");
        address validator = makeAddr("validator");
        bool isActive = true;

        vm.expectRevert(ERROR_ONLY_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        adminFacet.setValidator(validator, isActive);
    }

    function test_deactivateValidator() public {
        address stateTransitionManager = adminFacetWrapper.util_getStateTransitionManager();
        address validator = makeAddr("validator");
        bool isActive = false;

        adminFacetWrapper.util_setValidator(validator, true);

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(stateTransitionManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }

    function test_reactivateValidator() public {
        address stateTransitionManager = adminFacetWrapper.util_getStateTransitionManager();
        address validator = makeAddr("validator");
        bool isActive = true;

        adminFacetWrapper.util_setValidator(validator, false);

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(stateTransitionManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(adminFacetWrapper.util_getValidator(validator), isActive);
    }
}
