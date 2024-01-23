// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest, ERROR_ONLY_GOVERNOR} from "./_Admin_Shared.t.sol";

contract SetPendingGovernorTest is AdminTest {
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);

    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");
        address newPendingGovernor = makeAddr("newPendingGovernor");

        vm.expectRevert(ERROR_ONLY_GOVERNOR);

        vm.startPrank(nonGovernor);
        adminFacet.setPendingGovernor(newPendingGovernor);
    }

    function test_successfulCall() public {
        address governor = adminFacetWrapper.util_getGovernor();
        address oldPendingGovernor = adminFacetWrapper.util_getPendingGovernor();
        address newPendingGovernor = makeAddr("newPendingGovernor");

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingGovernor(oldPendingGovernor, newPendingGovernor);

        vm.startPrank(governor);
        adminFacet.setPendingGovernor(newPendingGovernor);

        assertEq(adminFacetWrapper.util_getPendingGovernor(), newPendingGovernor);
    }
}
