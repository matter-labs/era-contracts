// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdminFacetTest} from "../../../contracts/dev-contracts/test/AdminFacetTest.sol";
import {console2 as console} from "forge-std/Script.sol";

contract GovernanceTest is Test {
    AdminFacetTest public adminFacet;

    function setUp() public {
        adminFacet = new AdminFacetTest();
    }

    function test_setValidator() public {
        address validatorAddress = makeAddr("random address");
        adminFacet.setValidator(validatorAddress, true);
        bool isValidator = adminFacet.isValidator(validatorAddress);

        assertTrue(isValidator);
    }

    function test_randomAddressFailsSetValidator() public {    
        address validatorAddress = makeAddr("random address");
        vm.expectRevert("Hyperchain: not state transition manager");

        vm.startBroadcast(makeAddr("random address"));
        adminFacet.setValidator(validatorAddress, true);
        vm.stopBroadcast();
    }

    function test_setPorterAvailability() public {
        adminFacet.setPorterAvailability(true);
        bool isPorterAvailable = adminFacet.getPorterAvailability();

        assertTrue(isPorterAvailable);
    }

    function test_randomAddressFailsSetPorterAvailability() public {
        vm.expectRevert("Hyperchain: not state transition manager");

        vm.startBroadcast(makeAddr("random address"));
        adminFacet.setPorterAvailability(false);
        vm.stopBroadcast();
    }

    function test_setPriorityTransactionMaxGas() public {
        uint256 gasLimit = 12345678;
        adminFacet.setPriorityTxMaxGasLimit(gasLimit);
        uint256 newGasLimit = adminFacet.getPriorityTxMaxGasLimit();

        assertEq(gasLimit, newGasLimit);
    }

    function test_randomAddressFailsSetPriorityTransactionMaxGas() public {
        uint256 gasLimit = 12345678;
        vm.expectRevert("Hyperchain: not state transition manager");

        vm.startBroadcast(makeAddr("random address"));
        adminFacet.setPriorityTxMaxGasLimit(gasLimit);
        vm.stopBroadcast();
    }

    function test_setPendingAdmin() public {
        address proposedAdmin = makeAddr("random address");
        adminFacet.setPendingAdmin(proposedAdmin);
        address pendingAdmin = adminFacet.getPendingAdmin();

        assertEq(proposedAdmin, pendingAdmin);
    }

    function test_resetPendingAdmin() public {
        address proposedAdmin = makeAddr("random address");
        adminFacet.setPendingAdmin(proposedAdmin);

        address newProposedAdmin = makeAddr("RANDOM_CALLER");
        adminFacet.setPendingAdmin(newProposedAdmin);
        address pendingAdmin = adminFacet.getPendingAdmin();

        assertEq(newProposedAdmin, pendingAdmin);
    }

    function test_failToacceptAdminFromNotProposedAccount() public {
        vm.expectRevert(bytes("n4"));

        vm.startBroadcast(makeAddr("random address"));
        adminFacet.acceptAdmin();
        vm.stopBroadcast();
    }

    function test_acceptAdmin() public {
        address proposedAdmin = makeAddr("random address");
        adminFacet.setPendingAdmin(proposedAdmin);

        vm.startBroadcast(proposedAdmin);
        adminFacet.acceptAdmin();
        vm.stopBroadcast();

        address newAdmin = adminFacet.getAdmin();

        assertEq(proposedAdmin, newAdmin);
    }
}