// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract AdminManagement is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_RevertWhen_IsNotAdminOrOwner() public {
        address newAdmin = makeAddr("newAdmin");

        vm.stopPrank();
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, newAdmin));
        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_SuccessfulSetPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_RevertWhen_IsNotNewAdminSender() public {
        address newAdmin = makeAddr("newAdmin");
        address random = makeAddr("random");

        chainContractAddress.setPendingAdmin(newAdmin);

        vm.stopPrank();
        vm.prank(random);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, random));
        chainContractAddress.acceptAdmin();
    }

    function test_RevertWhen_PendingAdminNotExists() public {
        address random = makeAddr("random");

        vm.stopPrank();
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, random));
        chainContractAddress.acceptAdmin();
    }

    function test_SuccessfulAcceptPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        chainContractAddress.setPendingAdmin(newAdmin);

        vm.stopPrank();
        vm.prank(newAdmin);
        chainContractAddress.acceptAdmin();

        assertEq(chainContractAddress.admin(), newAdmin);
    }
}
