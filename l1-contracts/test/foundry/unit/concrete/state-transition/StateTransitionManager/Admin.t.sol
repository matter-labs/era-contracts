// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";

contract AdminTest is StateTransitionManagerTest {
    function test_setPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, true, false);
        emit IStateTransitionManager.NewPendingAdmin(address(0), newAdmin);
        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_acceptPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        chainContractAddress.setPendingAdmin(newAdmin);

        // Need this because in shared setup we start a prank as the governor
        vm.stopPrank();
        vm.prank(newAdmin);
        vm.expectEmit(true, true, true, false);
        emit IStateTransitionManager.NewPendingAdmin(newAdmin, address(0));
        vm.expectEmit(true, true, true, false);
        emit IStateTransitionManager.NewAdmin(address(0), newAdmin);
        chainContractAddress.acceptAdmin();

        address currentAdmin = chainContractAddress.admin();

        assertEq(currentAdmin, newAdmin);
    }
}
