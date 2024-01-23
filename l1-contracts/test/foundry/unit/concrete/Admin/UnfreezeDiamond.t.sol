// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_ADMIN_OR_GOVERNOR} from "./_Admin_Shared.t.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonGovernorOrAdmin() public {
        address nonGovernorOrAdmin = makeAddr("nonGovernorOrAdmin");

        vm.expectRevert(ERROR_ONLY_ADMIN_OR_GOVERNOR);

        vm.startPrank(nonGovernorOrAdmin);
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
