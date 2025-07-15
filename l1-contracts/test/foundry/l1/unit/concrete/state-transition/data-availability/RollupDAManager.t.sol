// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Import Foundry's Test framework
import {Test} from "forge-std/Test.sol";

// Import the RollupDAManager contract
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

import {ZeroAddress, InvalidL2DACommitmentScheme} from "contracts/common/L1ContractErrors.sol";

contract RollupDAManagerTest is Test {
    // Instance of the contract under test
    RollupDAManager rollupDAManager;

    // Addresses used in tests
    address owner = address(0x1);
    address newOwner = address(0x2);
    address nonOwner = address(0x3);
    address l1DAValidator1 = address(0x4);
    address l1DAValidator2 = address(0x6);
    address zeroAddress = address(0);

    // Events from the RollupDAManager contract
    event DAPairUpdated(address indexed l1DAValidator, L2DACommitmentScheme indexed l2DACommitmentScheme, bool status);

    // setUp is run before each test
    function setUp() public {
        // Deploy the contract as the owner
        vm.startPrank(owner);
        rollupDAManager = new RollupDAManager();
        vm.stopPrank();
    }

    /* ========== Deployment Tests ========== */

    function testOwnerIsSetCorrectly() public view {
        assertEq(rollupDAManager.owner(), owner, "Owner should be set correctly");
    }

    /* ========== Access Control Tests ========== */

    function testOnlyOwnerCanUpdateDAPair() public {
        // Attempt to update DA pair as owner
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, true);
        rollupDAManager.updateDAPair(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, true);
        vm.stopPrank();

        // Attempt to update DA pair as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        rollupDAManager.updateDAPair(l1DAValidator2, L2DACommitmentScheme.EMPTY_NO_DA, true);
        vm.stopPrank();
    }

    function testUpdateDAPairRevertsOnInvalidInput() public {
        vm.startPrank(owner);

        // L1DAValidator zero
        vm.expectRevert(ZeroAddress.selector);
        rollupDAManager.updateDAPair(zeroAddress, L2DACommitmentScheme.EMPTY_NO_DA, true);

        // L2DACommitmentScheme NONE
        vm.expectRevert(abi.encodeWithSelector(InvalidL2DACommitmentScheme.selector, uint8(L2DACommitmentScheme.NONE)));
        rollupDAManager.updateDAPair(l1DAValidator1, L2DACommitmentScheme.NONE, true);

        // Both inputs are invalid
        vm.expectRevert(ZeroAddress.selector);
        rollupDAManager.updateDAPair(zeroAddress, L2DACommitmentScheme.NONE, true);

        vm.stopPrank();
    }

    /* ========== Functionality Tests ========== */

    function testUpdateDAPairSetsAllowedDAPairsMapping() public {
        vm.startPrank(owner);

        // Initially, the pair should not be allowed
        bool allowed = rollupDAManager.isPairAllowed(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA);
        assertFalse(allowed, "DA pair should initially be disallowed");

        // Update the DA pair to allowed
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, true);
        rollupDAManager.updateDAPair(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, true);
        allowed = rollupDAManager.isPairAllowed(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA);
        assertTrue(allowed, "DA pair should be allowed after update");

        // Update the DA pair to disallowed
        vm.expectEmit(true, true, false, true);
        emit DAPairUpdated(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, false);
        rollupDAManager.updateDAPair(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, false);
        allowed = rollupDAManager.isPairAllowed(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA);
        assertFalse(allowed, "DA pair should be disallowed after update");

        vm.stopPrank();
    }

    function testUpdateMultipleDAPairs() public {
        vm.startPrank(owner);

        // Update multiple DA pairs
        rollupDAManager.updateDAPair(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA, true);
        rollupDAManager.updateDAPair(l1DAValidator2, L2DACommitmentScheme.PUBDATA_KECCAK256, true);

        // Check both pairs
        bool allowed1 = rollupDAManager.isPairAllowed(l1DAValidator1, L2DACommitmentScheme.EMPTY_NO_DA);
        bool allowed2 = rollupDAManager.isPairAllowed(l1DAValidator2, L2DACommitmentScheme.PUBDATA_KECCAK256);

        assertTrue(allowed1, "First DA pair should be allowed");
        assertTrue(allowed2, "Second DA pair should be allowed");

        vm.stopPrank();
    }
}
