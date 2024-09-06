// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, DiamondFreezeIncorrectState, DiamondNotFrozen} from "contracts/common/L1ContractErrors.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));
        vm.startPrank(nonStateTransitionManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address admin = utilsFacet.util_getStateTransitionManager();

        utilsFacet.util_setIsFrozen(false);

        vm.expectRevert(DiamondNotFrozen.selector);

        vm.startPrank(admin);
        adminFacet.unfreezeDiamond();
    }
}
