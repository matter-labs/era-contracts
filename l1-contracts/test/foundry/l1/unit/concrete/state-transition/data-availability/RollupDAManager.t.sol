// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Import Foundry's Test framework
import {Test} from "forge-std/Test.sol";

// Import the RollupDAManager contract
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract RollupDAManagerTest is Test {
    // Instance of the contract under test
    RollupDAManager rollupDAManager;

    // Addresses used in tests
    address owner = address(0x1);
    address newOwner = address(0x2);
    address nonOwner = address(0x3);
    address l1DAValidator1 = address(0x4);
    address l2DAValidator1 = address(0x5);
    address l1DAValidator2 = address(0x6);
    address l2DAValidator2 = address(0x7);
    address zeroAddress = address(0);

    // Events from the RollupDAManager contract
    event DAPairUpdated(address indexed l1DAValidator, address indexed l2DAValidator, bool status);

    // setUp is run before each test
    function setUp() public {
        // Deploy the contract as the owner
        vm.startPrank(owner);
        rollupDAManager = new RollupDAManager();
        vm.stopPrank();
    }

    /* ========== Deployment Tests ========== */

    function testOwnerIsSetCorrectly() public {
        assertEq(rollupDAManager.owner(), owner, "Owner should be set correctly");
    }

    /* ========== Access Control Tests ========== */

    function testOnlyOwnerCanUpdateDAPair() public {
        // Attempt to update DA pair as owner
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, l2DAValidator1, true);
        rollupDAManager.updateDAPair(l1DAValidator1, l2DAValidator1, true);
        vm.stopPrank();

        // Attempt to update DA pair as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        rollupDAManager.updateDAPair(l1DAValidator2, l2DAValidator2, true);
        vm.stopPrank();
    }

    function testUpdateDAPairRevertsOnZeroAddresses() public {
        vm.startPrank(owner);

        // Both addresses zero
        vm.expectRevert(ZeroAddress.selector);
        rollupDAManager.updateDAPair(zeroAddress, zeroAddress, true);

        // L1DAValidator zero
        vm.expectRevert(ZeroAddress.selector);
        rollupDAManager.updateDAPair(zeroAddress, l2DAValidator1, true);

        // L2DAValidator zero
        vm.expectRevert(ZeroAddress.selector);
        rollupDAManager.updateDAPair(l1DAValidator1, zeroAddress, true);

        vm.stopPrank();
    }

    /* ========== Functionality Tests ========== */

    function testUpdateDAPairSetsAllowedDAPairsMapping() public {
        vm.startPrank(owner);

        // Initially, the pair should not be allowed
        bool allowed = rollupDAManager.isPairAllowed(l1DAValidator1, l2DAValidator1);
        assertFalse(allowed, "DA pair should initially be disallowed");

        // Update the DA pair to allowed
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, l2DAValidator1, true);
        rollupDAManager.updateDAPair(l1DAValidator1, l2DAValidator1, true);
        allowed = rollupDAManager.isPairAllowed(l1DAValidator1, l2DAValidator1);
        assertTrue(allowed, "DA pair should be allowed after update");

        // Update the DA pair to disallowed
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, l2DAValidator1, false);
        rollupDAManager.updateDAPair(l1DAValidator1, l2DAValidator1, false);
        allowed = rollupDAManager.isPairAllowed(l1DAValidator1, l2DAValidator1);
        assertFalse(allowed, "DA pair should be disallowed after update");

        vm.stopPrank();
    }

    function testUpdateMultipleDAPairs() public {
        vm.startPrank(owner);

        // Update multiple DA pairs
        rollupDAManager.updateDAPair(l1DAValidator1, l2DAValidator1, true);
        rollupDAManager.updateDAPair(l1DAValidator2, l2DAValidator2, true);

        // Check both pairs
        bool allowed1 = rollupDAManager.isPairAllowed(l1DAValidator1, l2DAValidator1);
        bool allowed2 = rollupDAManager.isPairAllowed(l1DAValidator2, l2DAValidator2);

        assertTrue(allowed1, "First DA pair should be allowed");
        assertTrue(allowed2, "Second DA pair should be allowed");

        vm.stopPrank();
    }
}
