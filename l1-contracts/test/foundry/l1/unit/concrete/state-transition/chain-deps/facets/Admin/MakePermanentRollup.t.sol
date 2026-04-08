// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

import {AlreadyPermanentRollup, InvalidDAForPermanentRollup, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract MakePermanentRollupTest is AdminTest {
    RollupDAManager internal rollupDAManager;
    address internal l1DAValidator;

    function setUp() public override {
        super.setUp();

        // Access the real RollupDAManager from the integration deployment
        rollupDAManager = RollupDAManager(ctmAddresses.daAddresses.rollupDAManager);
        l1DAValidator = ctmAddresses.daAddresses.l1RollupDAValidator;
    }

    function test_getRollupDAManager() public {
        address manager = adminFacet.getRollupDAManager();
        assertTrue(manager != address(0), "RollupDAManager should be set");
    }

    function test_RevertWhen_MakePermanentRollupCalledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_InvalidDAForPermanentRollup() public {
        // Set an invalid DA pair that is not in the RollupDAManager
        address admin = utilsFacet.util_getAdmin();
        address badValidator = makeAddr("badValidator");

        vm.prank(admin);
        adminFacet.setDAValidatorPair(badValidator, L2DACommitmentScheme.PUBDATA_KECCAK256);

        vm.prank(admin);
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_AlreadyPermanentRollup() public {
        address admin = utilsFacet.util_getAdmin();

        // Set a valid DA pair (the one from deployment is already valid)
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        // Make it permanent
        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Try to make it permanent again - should revert
        vm.prank(admin);
        vm.expectRevert(AlreadyPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_MakePermanentRollupSuccess() public {
        address admin = utilsFacet.util_getAdmin();

        // Set a valid DA pair
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        // Now make it permanent
        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Verify it's permanent by trying to make it permanent again
        vm.prank(admin);
        vm.expectRevert(AlreadyPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_SetDAValidatorPairOnPermanentRollupWithInvalidPair() public {
        address admin = utilsFacet.util_getAdmin();

        // Set a valid DA pair and make it permanent
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Try to set an invalid DA pair
        address invalidValidator = makeAddr("invalidValidator");
        vm.prank(admin);
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        adminFacet.setDAValidatorPair(invalidValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
    }

    function test_SetDAValidatorPairOnPermanentRollupWithValidPair() public {
        address admin = utilsFacet.util_getAdmin();

        // Set a valid DA pair and make it permanent
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Add another valid DA pair to the manager
        address anotherValidator = makeAddr("anotherValidator");
        address rollupDAManagerOwner = RollupDAManager(address(rollupDAManager)).owner();
        vm.prank(rollupDAManagerOwner);
        rollupDAManager.updateDAPair(anotherValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256, true);

        // Setting to another allowed pair should succeed
        vm.prank(admin);
        adminFacet.setDAValidatorPair(anotherValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
    }
}
