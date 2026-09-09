// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {
    AirbenderLaneRequiresMultiProof,
    AirbenderLaneRequiresSettledBatch,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches,
    InvalidDisabledProofSystemsMask,
    InvalidProofSystem,
    MustBeEraChain,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED, BOOJUM_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Unit tests for `setProofSystemStatus`, which turns one of the chain's proof systems on or off.
/// @dev Era chains settle behind two independent proof systems. Either may be switched off by the chain
/// admin to keep the chain live through a prover incident, but never both: with both off a batch would
/// settle without being proved at all. One system per call, so the never-both rule is a check on what the
/// pair becomes rather than on the argument.
contract SetProofSystemStatusTest is AdminTest {
    event NewDisabledProofSystems(uint8 indexed oldDisabledProofSystems, uint8 indexed newDisabledProofSystems);

    /// Brings the chain to the state where the Airbender lane may be required: committing Airbender data,
    /// with one settled batch for the lane's first batch to chain to, and nothing in flight.
    function _readyForTheAirbenderLane() internal {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setTotalBatchesCommitted(1);
        utilsFacet.util_setTotalBatchesVerified(1);
    }

    /// A new chain starts with the Airbender lane masked off, because it also starts without the
    /// capability that lane needs: its batches carry no Airbender commitment until an admin declares
    /// otherwise, and the lane cannot be required before then.
    function test_defaultsToTheAirbenderLaneMaskedOff() public view {
        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, false);
    }

    function test_revertWhen_notEraChain() public {
        utilsFacet.util_setZksyncOS(true);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(MustBeEraChain.selector);
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, false);
    }

    /// Proof-system policy belongs to the layer the chain settles on. Written anywhere else it would
    /// sit stale and take effect on return.
    function test_revertWhen_notOnTheSettlementLayer() public {
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(NotSettlementLayer.selector);
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, false);
    }

    /// The argument names one system by its own bit. A mask, a bit index or a proof-envelope type would
    /// each be a plausible thing to pass, and none of them names a proof system.
    function testFuzz_revertWhen_argumentIsNotASingleKnownSystem(uint8 _proofSystem) public {
        vm.assume(_proofSystem != BOOJUM_PROOF_SYSTEM_DISABLED && _proofSystem != AIRBENDER_PROOF_SYSTEM_DISABLED);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystem.selector, _proofSystem));
        adminFacet.setProofSystemStatus(_proofSystem, false);
    }

    /// The kill switch, exercised from a chain that has the lane brought up.
    function test_disablesAirbender() public {
        _readyForTheAirbenderLane();
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(0, AIRBENDER_PROOF_SYSTEM_DISABLED);
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    function test_disablesBoojum() public {
        _readyForTheAirbenderLane();
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(BOOJUM_PROOF_SYSTEM_DISABLED, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), BOOJUM_PROOF_SYSTEM_DISABLED);
    }

    function test_restoresBothRequired() public {
        _readyForTheAirbenderLane();

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    /// Switching the second one off would leave the chain settling with no proof system at all. One bit
    /// alone cannot say that, so the rule is checked on the mask the call would produce.
    function test_revertWhen_disablingTheSecondSystem() public {
        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
        uint8 both = BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED;

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, both));
        adminFacet.setProofSystemStatus(BOOJUM_PROOF_SYSTEM_DISABLED, false);
    }

    /// Requiring the Airbender lane before the chain commits Airbender data would stall it on the very
    /// next batch: the Executor emits one public input and the enabled lane has nothing to read.
    function test_revertWhen_requiringAirbenderWithoutMultiProof() public {
        utilsFacet.util_setTotalBatchesCommitted(1);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(AirbenderLaneRequiresMultiProof.selector);
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, true);
    }

    /// The Airbender preconditions are read off the resulting mask, not off the bit the call names, so a
    /// call that leaves the lane required has to satisfy them even when it never touches that bit.
    function test_revertWhen_aCallLeavesAirbenderRequiredWithoutMultiProof() public {
        utilsFacet.util_setDisabledProofSystems(0);
        utilsFacet.util_setTotalBatchesCommitted(1);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(AirbenderLaneRequiresMultiProof.selector);
        adminFacet.setProofSystemStatus(BOOJUM_PROOF_SYSTEM_DISABLED, false);
    }

    /// A chain that has settled nothing has only its genesis batch to chain the lane's first batch
    /// to, and the genesis commitment is a configured value with no preimage the guest can open. The
    /// drained-pipeline check does not catch this: at genesis both counters are zero, so it passes.
    function test_revertWhen_requiringAirbenderBeforeAnyBatchHasSettled() public {
        utilsFacet.util_setMultiProofEnabled(true);
        assertEq(utilsFacet.util_getTotalBatchesVerified(), 0);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(AirbenderLaneRequiresSettledBatch.selector);
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, true);
    }

    /// One settled batch of the chain's own is enough: its commitment is one the sequencer built and
    /// can open.
    function test_requiresAirbenderOnceABatchHasSettled() public {
        _readyForTheAirbenderLane();

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    /// Requiring a lane again is the one direction that can strand batches: those committed while it
    /// was off carry a single public input the lane has nothing to read, so the gate refuses them and
    /// the chain stalls behind the oldest. Draining first is the only order that works.
    function test_revertWhen_requiringAirbenderWithUnverifiedBatches() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, true);
    }

    /// The same guard on the other lane, so it is the enable direction being tested and not the
    /// Airbender bit specifically.
    function test_revertWhen_requiringBoojumWithUnverifiedBatches() public {
        utilsFacet.util_setMultiProofEnabled(true);
        utilsFacet.util_setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setProofSystemStatus(BOOJUM_PROOF_SYSTEM_DISABLED, true);
    }

    /// Enabling a system that is already on changes nothing, so the drain it would otherwise need does
    /// not apply. Requiring one here would refuse the call that merely restates the chain's own state.
    function test_enablingAnAlreadyEnabledSystemNeedsNoDrain() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);
        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED, AIRBENDER_PROOF_SYSTEM_DISABLED);
        adminFacet.setProofSystemStatus(BOOJUM_PROOF_SYSTEM_DISABLED, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    /// The switch exists for the case where committed batches cannot be proved, so it has to take effect
    /// while those batches are still waiting.
    function test_appliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(AIRBENDER_PROOF_SYSTEM_DISABLED, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }
}
