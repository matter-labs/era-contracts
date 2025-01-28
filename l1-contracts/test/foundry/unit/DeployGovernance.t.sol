// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdminFacetTest} from "../../../contracts/dev-contracts/test/AdminFacetTest.sol";
import {Unauthorized} from "../../../contracts/common/L1ContractErrors.sol";

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
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));

        vm.startBroadcast(caller);
        adminFacet.setValidator(validatorAddress, true);
        vm.stopBroadcast();
    }

    function test_setPorterAvailability() public {
        adminFacet.setPorterAvailability(true);
        bool isPorterAvailable = adminFacet.getPorterAvailability();

        assertTrue(isPorterAvailable);
    }

    function test_randomAddressFailsSetPorterAvailability() public {
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));

        vm.startBroadcast(caller);
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
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));

        vm.startBroadcast(caller);
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
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));

        vm.startBroadcast(caller);
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