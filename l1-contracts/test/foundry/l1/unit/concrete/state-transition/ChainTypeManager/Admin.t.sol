// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";

contract AdminTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_setPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, true, false);
        emit IChainTypeManager.NewPendingAdmin(address(0), newAdmin);
        chainContractAddress.setPendingAdmin(newAdmin);
    }

    function test_acceptPendingAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        chainContractAddress.setPendingAdmin(newAdmin);

        // Need this because in shared setup we start a prank as the governor
        vm.stopPrank();
        vm.prank(newAdmin);
        vm.expectEmit(true, true, true, false);
        emit IChainTypeManager.NewPendingAdmin(newAdmin, address(0));
        vm.expectEmit(true, true, true, false);
        emit IChainTypeManager.NewAdmin(address(0), newAdmin);
        chainContractAddress.acceptAdmin();

        address currentAdmin = chainContractAddress.admin();

        assertEq(currentAdmin, newAdmin);
    }
}
