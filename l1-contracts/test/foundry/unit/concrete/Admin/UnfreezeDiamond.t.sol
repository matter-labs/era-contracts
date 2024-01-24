// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER} from "./_Admin_Shared.t.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonGovernorOrStateTransitionManager() public {
        address nonGovernorOrStateTransitionManager = makeAddr("nonGovernorOrStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonGovernorOrStateTransitionManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address governor = adminFacetWrapper.util_getGovernor();

        adminFacetWrapper.util_setIsFrozen(false);

        vm.expectRevert(bytes.concat("a7"));

        vm.startPrank(governor);
        adminFacet.unfreezeDiamond();
    }

    function test_successfulFreeze() public {
        address governor = adminFacetWrapper.util_getGovernor();

        adminFacetWrapper.util_setIsFrozen(true);

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit Unfreeze();

        vm.startPrank(governor);
        adminFacet.unfreezeDiamond();

        assertEq(adminFacetWrapper.util_getIsFrozen(), false);
    }
}
