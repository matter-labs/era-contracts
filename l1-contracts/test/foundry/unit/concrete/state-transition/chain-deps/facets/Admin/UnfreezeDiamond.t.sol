// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_STATE_TRANSITION_MANAGER} from "../Base/_Base_Shared.t.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(ERROR_ONLY_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address admin = utilsFacet.util_getStateTransitionManager();

        utilsFacet.util_setIsFrozen(false);

        vm.expectRevert(bytes.concat("a7"));

        vm.startPrank(admin);
        adminFacet.unfreezeDiamond();
    }
}
