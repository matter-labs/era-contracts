// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER} from "../Base/_Base_Shared.t.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonAdminOrStateTransitionManager() public {
        address nonAdminOrStateTransitionManager = makeAddr("nonAdminOrStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_ADMIN_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonAdminOrStateTransitionManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address admin = utilsFacet.util_getAdmin();

        utilsFacet.util_setIsFrozen(false);

        vm.expectRevert(bytes.concat("a7"));

        vm.startPrank(admin);
        adminFacet.unfreezeDiamond();
    }
}
