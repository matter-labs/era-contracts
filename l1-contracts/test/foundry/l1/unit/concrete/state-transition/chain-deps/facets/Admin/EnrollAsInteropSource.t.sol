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

import {AlreadyInteropSource, InvalidDAForInteropSource, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotZKsyncOS} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Regression for the atomic-interop source enrollment latch on the {AdminFacet}: an
/// interop source MUST use the `L2_TO_L1_ONLY` DA scheme (so its full L2->L1 region is published as
/// permanent calldata and consumers can rebuild its IMT for timeout proofs), the feature is ZKsync-OS
/// only, and once enrolled the chain cannot downgrade away from an interop-source DA scheme (one-way
/// latch, mirroring `makePermanentRollup`).
contract EnrollAsInteropSourceTest is AdminTest {
    RollupDAManager internal rollupDAManager;
    address internal l1DAValidator;

    function getExtendedAdminSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IAdmin.setDAValidatorPair.selector;
        selectors[1] = IAdmin.makePermanentRollup.selector;
        selectors[2] = IAdmin.enrollAsInteropSource.selector;
        return selectors;
    }

    function setUp() public override {
        rollupDAManager = new RollupDAManager();
        l1DAValidator = makeAddr("l1DAValidator");

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        // Use the ERA chain id (block.chainid) as L1 chain id so onlyL1/onlySettlementLayer pass.
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

    /// @dev Move the chain to ZKsync OS + `L2_TO_L1_ONLY` DA — the prerequisites for enrollment.
    function _prepareZksyncOsWithInteropDa() internal {
        utilsFacet.util_setZksyncOS(true);
        address admin = utilsFacet.util_getAdmin();
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.L2_TO_L1_ONLY);
    }

    function test_RevertWhen_EnrollCalledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.enrollAsInteropSource();
    }

    function test_RevertWhen_NotZksyncOS() public {
        // Era VM chain (zksyncOS == false) cannot be an interop source.
        utilsFacet.util_setZksyncOS(false);
        address admin = utilsFacet.util_getAdmin();
        vm.prank(admin);
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.enrollAsInteropSource();
    }

    function test_RevertWhen_DaSchemeNotInteropSource() public {
        // ZKsync OS, but the DA scheme is BLOBS_ZKSYNC_OS (blob-based, expires) — not an interop-source
        // scheme. Enrollment must reject it.
        utilsFacet.util_setZksyncOS(true);
        address admin = utilsFacet.util_getAdmin();
        vm.prank(admin);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidDAForInteropSource.selector, L2DACommitmentScheme.BLOBS_ZKSYNC_OS)
        );
        adminFacet.enrollAsInteropSource();
    }

    function test_EnrollSuccess_emitsAndLatches() public {
        _prepareZksyncOsWithInteropDa();
        address admin = utilsFacet.util_getAdmin();

        vm.expectEmit(false, false, false, true);
        emit IAdmin.InteropSourceEnrolled();
        vm.prank(admin);
        adminFacet.enrollAsInteropSource();

        // Latched: a second enrollment reverts, proving `isInteropSource` was set.
        vm.prank(admin);
        vm.expectRevert(AlreadyInteropSource.selector);
        adminFacet.enrollAsInteropSource();
    }

    function test_RevertWhen_DowngradeDaAfterEnrollment() public {
        _prepareZksyncOsWithInteropDa();
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        adminFacet.enrollAsInteropSource();

        // The one-way latch forbids downgrading away from an interop-source DA scheme: switching to
        // BLOBS_ZKSYNC_OS (which would stop publishing the L2->L1 region permanently) must revert.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidDAForInteropSource.selector, L2DACommitmentScheme.BLOBS_ZKSYNC_OS)
        );
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);
    }

    function test_SetDAValidatorPair_RevertsL2ToL1OnlyOnNonZksyncOS() public {
        // L2_TO_L1_ONLY (and BLOBS_ZKSYNC_OS) are ZKsync-OS-only; setting them on an Era VM chain
        // reverts, so an unusable DA pair can never be configured.
        utilsFacet.util_setZksyncOS(false);
        address admin = utilsFacet.util_getAdmin();
        vm.prank(admin);
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.setDAValidatorPair(l1DAValidator, L2DACommitmentScheme.L2_TO_L1_ONLY);
    }
}
