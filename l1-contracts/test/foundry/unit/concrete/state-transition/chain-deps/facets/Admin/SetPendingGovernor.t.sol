// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_GOVERNOR} from "../Base/_Base_Shared.t.sol";

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
        address governor = utilsFacet.util_getGovernor();
        address oldPendingGovernor = utilsFacet.util_getPendingGovernor();
        address newPendingGovernor = makeAddr("newPendingGovernor");

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingGovernor(oldPendingGovernor, newPendingGovernor);

        vm.startPrank(governor);
        adminFacet.setPendingGovernor(newPendingGovernor);

        assertEq(utilsFacet.util_getPendingGovernor(), newPendingGovernor);
    }
}
