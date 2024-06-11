// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_STATE_TRANSITION_MANAGER} from "../Base/_Base_Shared.t.sol";

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
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();
        address validator = makeAddr("validator");
        bool isActive = false;

        utilsFacet.util_setValidator(validator, true);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(stateTransitionManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(utilsFacet.util_getValidator(validator), isActive);
    }

    function test_reactivateValidator() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();
        address validator = makeAddr("validator");
        bool isActive = true;

        utilsFacet.util_setValidator(validator, false);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidatorStatusUpdate(validator, isActive);

        vm.startPrank(stateTransitionManager);
        adminFacet.setValidator(validator, isActive);

        assertEq(utilsFacet.util_getValidator(validator), isActive);
    }
}
