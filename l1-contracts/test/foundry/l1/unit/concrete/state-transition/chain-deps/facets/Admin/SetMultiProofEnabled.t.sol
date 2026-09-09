// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {AirbenderLaneMustBeDisabled, MustBeEraChain, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Unit tests for the per-chain multi-proof capability.
/// @dev The setting says whether the chain commits the extra Airbender data every batch needs to be
/// provable on that lane. It is a deployment property rather than an incident switch: it decides what
/// `Committer` accepts at commit time, whereas `setProofSystemStatus` decides which lanes have to
/// verify a batch already committed.
contract SetMultiProofEnabledTest is AdminTest {
    event NewMultiProofEnabled(bool oldMultiProofEnabled, bool newMultiProofEnabled);

    function test_defaultsToDisabled() public view {
        assertFalse(utilsFacet.util_getMultiProofEnabled());
    }

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setMultiProofEnabled(true);
    }

    /// The Airbender lane is an Era construction; a ZKsync OS chain has no second commitment to carry.
    function test_revertWhen_notEraChain() public {
        utilsFacet.util_setZksyncOS(true);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(MustBeEraChain.selector);
        adminFacet.setMultiProofEnabled(true);
    }

    function test_enables() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewMultiProofEnabled(false, true);
        adminFacet.setMultiProofEnabled(true);

        assertTrue(utilsFacet.util_getMultiProofEnabled());
    }

    function test_disables() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setMultiProofEnabled(true);
        adminFacet.setMultiProofEnabled(false);

        assertFalse(utilsFacet.util_getMultiProofEnabled());
    }

    /// Withdrawing the capability under a required lane would put the next batch in a shape the gate
    /// rejects, so the lane has to be masked off first — the reverse of how it was brought up.
    function test_revertWhen_disablingWhileAirbenderLaneRequired() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(AirbenderLaneMustBeDisabled.selector);
        adminFacet.setMultiProofEnabled(false);
    }

    /// And the same rule in the enable direction, so the guard reads as one symmetric condition
    /// rather than two special cases.
    function test_revertWhen_enablingWhileAirbenderLaneRequired() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setDisabledProofSystems(0);
        utilsFacet.util_setMultiProofEnabled(false);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(AirbenderLaneMustBeDisabled.selector);
        adminFacet.setMultiProofEnabled(true);
    }

    /// Proof-system policy belongs to the layer the chain settles on.
    function test_revertWhen_notOnTheSettlementLayer() public {
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(NotSettlementLayer.selector);
        adminFacet.setMultiProofEnabled(true);
    }

    /// A pipeline still holding unproven batches is fine: the lane is masked off, so the gate takes
    /// both shapes, and `ExecutorFacet` reads each batch's shape from its own stored data rather than
    /// from this setting. Requiring a drain here would stop commitment for no reason.
    function test_appliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setMultiProofEnabled(true);

        assertTrue(utilsFacet.util_getMultiProofEnabled());
        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }
}
