// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";

contract AcceptGovernorTest is AdminTest {
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    function test_revertWhen_calledByNonPendingGovernor() public {
        address nonPendingGovernor = makeAddr("nonPendingGovernor");

        vm.expectRevert(bytes.concat("n4"));

        vm.startPrank(nonPendingGovernor);
        adminFacet.acceptGovernor();
    }

    function test_successfulCall() public {
        address pendingGovernor = utilsFacet.util_getPendingGovernor();
        address previousGovernor = utilsFacet.util_getGovernor();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingGovernor(pendingGovernor, address(0));
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewGovernor(previousGovernor, pendingGovernor);

        vm.startPrank(pendingGovernor);
        adminFacet.acceptGovernor();

        assertEq(utilsFacet.util_getPendingGovernor(), address(0));
        assertEq(utilsFacet.util_getGovernor(), pendingGovernor);
    }
}
