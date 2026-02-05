// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Unauthorized, AlreadyPermanentRollup, InvalidDAForPermanentRollup} from "contracts/common/L1ContractErrors.sol";

contract MakePermanentRollupTest is AdminTest {
    RollupDAManager internal rollupDAManager;
    address internal l1DAValidator;

    function getExtendedAdminSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](18);
        uint256 i = 0;
        selectors[i++] = IAdmin.setPendingAdmin.selector;
        selectors[i++] = IAdmin.acceptAdmin.selector;
        selectors[i++] = IAdmin.setValidator.selector;
        selectors[i++] = IAdmin.setPorterAvailability.selector;
        selectors[i++] = IAdmin.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = IAdmin.changeFeeParams.selector;
        selectors[i++] = IAdmin.setTokenMultiplier.selector;
        selectors[i++] = IAdmin.upgradeChainFromVersion.selector;
        selectors[i++] = IAdmin.executeUpgrade.selector;
        selectors[i++] = IAdmin.freezeDiamond.selector;
        selectors[i++] = IAdmin.unfreezeDiamond.selector;
        selectors[i++] = IAdmin.pauseDepositsBeforeInitiatingMigration.selector;
        selectors[i++] = IAdmin.unpauseDeposits.selector;
        selectors[i++] = IAdmin.setTransactionFilterer.selector;
        selectors[i++] = IAdmin.setPubdataPricingMode.selector;
        selectors[i++] = IAdmin.setDAValidatorPair.selector;
        // New selectors for permanent rollup tests
        selectors[i++] = IAdmin.getRollupDAManager.selector;
        selectors[i++] = IAdmin.makePermanentRollup.selector;
        return selectors;
    }

    function setUp() public override {
        // Create a real RollupDAManager for testing
        rollupDAManager = new RollupDAManager();
        l1DAValidator = makeAddr("l1DAValidator");

        // Add the DA pair to the manager
        rollupDAManager.updateDAPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256, true);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        // Use the ERA chain id (block.chainid) as L1 chain id so onlyL1 passes
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet(block.chainid, rollupDAManager, false)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getExtendedAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        dummyBridgehub = new DummyBridgehub();
        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier, address(dummyBridgehub));
        adminFacet = IAdmin(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    function test_getRollupDAManager() public {
        address manager = adminFacet.getRollupDAManager();
        assertEq(manager, address(rollupDAManager));
    }

    function test_RevertWhen_MakePermanentRollupCalledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_InvalidDAForPermanentRollup() public {
        // The default DA pair is not set, so it should fail
        address admin = utilsFacet.util_getAdmin();
        vm.prank(admin);
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_AlreadyPermanentRollup() public {
        address admin = utilsFacet.util_getAdmin();

        // First set a valid DA pair
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

        // Set a valid DA pair first
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

        // First set a valid DA pair and make it permanent
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Now try to set an invalid DA pair (different validator not in the allowed list)
        address invalidValidator = makeAddr("invalidValidator");

        vm.prank(admin);
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        adminFacet.setDAValidatorPair(invalidValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
    }

    function test_SetDAValidatorPairOnPermanentRollupWithValidPair() public {
        address admin = utilsFacet.util_getAdmin();

        // First set a valid DA pair and make it permanent
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // Add another valid DA pair to the manager
        address anotherValidator = makeAddr("anotherValidator");
        rollupDAManager.updateDAPair(anotherValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256, true);

        // Setting to another allowed pair should succeed
        vm.prank(admin);
        adminFacet.setDAValidatorPair(anotherValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
    }
}
