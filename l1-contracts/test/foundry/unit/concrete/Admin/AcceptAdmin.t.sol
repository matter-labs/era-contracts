// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";

contract AcceptAdminTest is AdminTest {
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    function setUp() public override {
        super.setUp();
        adminFacetWrapper.util_setPendingAdmin(makeAddr("pendingAdmin"));
    }

    function test_revertWhen_calledByNonPendingAdmin() public {
        address nonPendingAdmin = makeAddr("nonPendingAdmin");

        vm.expectRevert(bytes.concat("n4"));

        vm.startPrank(nonPendingAdmin);
        adminFacet.acceptAdmin();
    }

    function test_successfulCall() public {
        address pendingAdmin = adminFacetWrapper.util_getPendingAdmin();
        address previousAdmin = adminFacetWrapper.util_getAdmin();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingAdmin(pendingAdmin, address(0));
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewAdmin(previousAdmin, pendingAdmin);

        vm.startPrank(pendingAdmin);
        adminFacet.acceptAdmin();

        assertEq(adminFacetWrapper.util_getPendingAdmin(), address(0));
        assertEq(adminFacetWrapper.util_getAdmin(), pendingAdmin);
    }
}
