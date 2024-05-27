// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

contract AdminManagement is StateTransitionManagerTest {
    function test_RevertWhen_IsNotAdminOrOwner() public {
        address newAdmin = makeAddr("newadmin");

        vm.stopPrank();
        vm.prank(newAdmin);
        vm.expectRevert(bytes("STM: not owner or admin"));
        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_SuccessfulSetPendingAdmin() public {
        address newAdmin = makeAddr("newadmin");

        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_RevertWhen_IsNotNewAdminSender() public {
        address newAdmin = makeAddr("newadmin");
        address random = makeAddr("random");

        chainContractAddress.setPendingAdmin(newAdmin);

        vm.stopPrank();
        vm.prank(random);
        vm.expectRevert(bytes("n42"));
        chainContractAddress.acceptAdmin();
    }

    function test_RevertWhen_PendingAdminNotExists() public {
        address random = makeAddr("random");

        vm.stopPrank();
        vm.prank(random);
        vm.expectRevert(bytes("n42"));
        chainContractAddress.acceptAdmin();
    }

    function test_SuccessfulAcceptPendingAdmin() public {
        address newAdmin = makeAddr("newadmin");

        chainContractAddress.setPendingAdmin(newAdmin);

        vm.stopPrank();
        vm.prank(newAdmin);
        chainContractAddress.acceptAdmin();

        assertEq(chainContractAddress.admin(), newAdmin);
    }
}
