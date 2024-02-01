// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER} from "../Base/_Base_Shared.t.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonGovernorOrStateTransitionManager() public {
        address nonGovernorOrStateTransitionManager = makeAddr("nonGovernorOrStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonGovernorOrStateTransitionManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address governor = utilsFacet.util_getGovernor();

        utilsFacet.util_setIsFrozen(false);

        vm.expectRevert(bytes.concat("a7"));

        vm.startPrank(governor);
        adminFacet.unfreezeDiamond();
    }

    // function test_successfulUnfreeze() public {
    //     address governor = utilsFacet.util_getGovernor();

    //     utilsFacet.util_setIsFrozen(true);

    //     vm.expectEmit(true, true, true, true, address(adminFacet));
    //     emit Unfreeze();

    //     vm.startPrank(governor);
    //     adminFacet.unfreezeDiamond();

    //     assertEq(utilsFacet.util_getIsFrozen(), false);
    // }
}
