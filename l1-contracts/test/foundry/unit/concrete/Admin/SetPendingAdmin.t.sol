// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_GOVERNOR} from "./_Admin_Shared.t.sol";

contract SetPendingAdminTest is AdminTest {
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");
        address newPendingAdmin = makeAddr("newPendingAdmin");

        vm.expectRevert(ERROR_ONLY_GOVERNOR);

        vm.startPrank(nonGovernor);
        adminFacet.setPendingAdmin(newPendingAdmin);
    }

    function test_successfulSet() public {
        address governor = adminFacetWrapper.util_getGovernor();
        address oldPendingAdmin = adminFacetWrapper.util_getPendingAdmin();
        address newPendingAdmin = makeAddr("newPendingAdmin");

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        vm.startPrank(governor);
        adminFacet.setPendingAdmin(newPendingAdmin);

        assertEq(adminFacetWrapper.util_getPendingAdmin(), newPendingAdmin);
    }
}
