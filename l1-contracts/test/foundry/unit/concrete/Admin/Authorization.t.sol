// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";

contract AuthorizationTest is AdminTest {
    function test_SetPendingAdmin_RevertWhen_AdminNotGovernanceOwner() public {
        address newAdmin = address(0x1337);
        vm.prank(owner);
        vm.expectRevert(bytes.concat("1g"));
        proxyAsAdmin.setPendingAdmin(newAdmin);
    }
}
