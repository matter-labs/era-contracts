// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {L2DACommitmentScheme, PubdataContent} from "contracts/common/Config.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

import {
    AlreadyPermanentRollup,
    InvalidDAForPermanentRollup,
    Unauthorized,
    PubdataContentLockedForPermanentRollup,
    NonFullPubdataContentForPermanentRollup
} from "contracts/common/L1ContractErrors.sol";
import {NotZKsyncOS} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract MakePermanentRollupTest is AdminTest {
    RollupDAManager internal rollupDAManager;
    address internal l1DAValidator;

    function getExtendedAdminSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](17);
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
        selectors[i++] = IAdmin.setTransactionFilterer.selector;
        selectors[i++] = IAdmin.setPubdataPricingMode.selector;
        selectors[i++] = IAdmin.setDAValidatorPair.selector;
        // New selectors for permanent rollup tests
        selectors[i++] = IAdmin.getRollupDAManager.selector;
        selectors[i++] = IAdmin.makePermanentRollup.selector;
        selectors[i++] = IAdmin.setPubdataContent.selector;
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
            facet: address(new AdminFacet(block.chainid, rollupDAManager)),
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
        mockChainTypeManagerVerifier(testnetVerifier);
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, address(dummyBridgehub));
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

    function test_RevertWhen_MakePermanentRollupWithNonFullPubdataContent() public {
        address admin = utilsFacet.util_getAdmin();
        // `setPubdataContent` is ZKsync OS only.
        utilsFacet.util_setZksyncOS(true);

        // Set a valid DA pair, but switch the chain to LOGS_ONLY mode.
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.setPubdataContent(PubdataContent.LOGS_ONLY);

        // A permanent rollup must publish full pubdata, so this must revert while in LOGS_ONLY mode.
        vm.prank(admin);
        vm.expectRevert(NonFullPubdataContentForPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_MakePermanentRollupAfterRevertingToFullPubdata() public {
        address admin = utilsFacet.util_getAdmin();
        // `setPubdataContent` is ZKsync OS only.
        utilsFacet.util_setZksyncOS(true);

        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        // Move to LOGS_ONLY and back to FULL_PUBDATA; the one-way lock only applies once permanent.
        vm.prank(admin);
        adminFacet.setPubdataContent(PubdataContent.LOGS_ONLY);
        vm.prank(admin);
        adminFacet.setPubdataContent(PubdataContent.FULL_PUBDATA);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        vm.prank(admin);
        vm.expectRevert(AlreadyPermanentRollup.selector);
        adminFacet.makePermanentRollup();
    }

    function test_RevertWhen_SetPubdataContentOnPermanentRollup() public {
        address admin = utilsFacet.util_getAdmin();
        // `setPubdataContent` is ZKsync OS only.
        utilsFacet.util_setZksyncOS(true);

        // Set a valid DA pair and make the chain a permanent rollup.
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);

        vm.prank(admin);
        adminFacet.makePermanentRollup();

        // The pubdata content is now locked; even setting it back to FULL_PUBDATA must revert.
        vm.prank(admin);
        vm.expectRevert(PubdataContentLockedForPermanentRollup.selector);
        adminFacet.setPubdataContent(PubdataContent.LOGS_ONLY);

        vm.prank(admin);
        vm.expectRevert(PubdataContentLockedForPermanentRollup.selector);
        adminFacet.setPubdataContent(PubdataContent.FULL_PUBDATA);
    }

    function test_SetPubdataContentSuccessWhenNotPermanentRollup() public {
        address admin = utilsFacet.util_getAdmin();
        // `setPubdataContent` is ZKsync OS only.
        utilsFacet.util_setZksyncOS(true);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(adminFacet));
        emit IAdmin.NewPubdataContent(PubdataContent.FULL_PUBDATA, PubdataContent.LOGS_ONLY);
        adminFacet.setPubdataContent(PubdataContent.LOGS_ONLY);
        assertEq(
            uint8(utilsFacet.util_getPubdataContent()),
            uint8(PubdataContent.LOGS_ONLY),
            "pubdata content not set to LOGS_ONLY"
        );

        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(adminFacet));
        emit IAdmin.NewPubdataContent(PubdataContent.LOGS_ONLY, PubdataContent.FULL_PUBDATA);
        adminFacet.setPubdataContent(PubdataContent.FULL_PUBDATA);
        assertEq(
            uint8(utilsFacet.util_getPubdataContent()),
            uint8(PubdataContent.FULL_PUBDATA),
            "pubdata content not set back to FULL_PUBDATA"
        );
    }

    function test_RevertWhen_SetPubdataContentOnNonZKsyncOSChain() public {
        address admin = utilsFacet.util_getAdmin();

        // The pubdata content has no meaning on Era-VM chains, so the setter is ZKsync OS only.
        vm.prank(admin);
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.setPubdataContent(PubdataContent.LOGS_ONLY);
    }
}
