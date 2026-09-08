// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {
    MultiProofRequiredWhileAirbenderLaneEnabled,
    MustBeEraChain,
    Unauthorized,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches
} from "contracts/common/L1ContractErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Unit tests for the per-chain multi-proof capability.
/// @dev The setting says whether the chain commits the extra Airbender data every batch needs to be
/// provable on that lane. It is a deployment property rather than an incident switch: it decides what
/// `Committer` accepts at commit time, whereas `setDisabledProofSystems` decides which lanes have to
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
        adminFacet.setDisabledProofSystems(0);

        // The lane has to stop being required before the data behind it is withdrawn.
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        adminFacet.setMultiProofEnabled(false);

        assertFalse(utilsFacet.util_getMultiProofEnabled());
    }

    /// Withdrawing the capability while the gate still requires the Airbender lane would stall the chain
    /// on the next batch, so the two settings can only be unwound in the order they were set.
    function test_revertWhen_disablingWhileAirbenderLaneRequired() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(MultiProofRequiredWhileAirbenderLaneEnabled.selector);
        adminFacet.setMultiProofEnabled(false);
    }

    /// Turning the capability on while batches are still in flight would strand them: they were
    /// committed without Airbender data, so the gate they now face has no second public input to give
    /// its Airbender lane.
    function test_revertWhen_enablingWithUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setMultiProofEnabled(true);
    }

    /// And turning it off strands them the other way: the committed batches carry an Airbender
    /// commitment, but batches committed after the change would not, so the two cannot be proved under
    /// one configuration.
    function test_revertWhen_disablingWithUnverifiedBatches() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setMultiProofEnabled(false);
    }

    /// A drained pipeline is the whole precondition: with every committed batch verified, the change
    /// applies to future batches only.
    function test_appliesOnADrainedPipeline() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(5);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setMultiProofEnabled(true);

        assertTrue(utilsFacet.util_getMultiProofEnabled());
    }
}
