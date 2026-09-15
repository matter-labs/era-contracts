// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches,
    InvalidDisabledProofSystemsMask,
    MustBeEraChain,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_MASK, BOOJUM_PROOF_SYSTEM_MASK, ProofSystem} from "contracts/common/Config.sol";

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
        utilsFacet.util_setTotalBatchesCommitted(1);
        utilsFacet.util_setTotalBatchesVerified(1);
    }

    /// A new chain requires every proof system, the same posture an upgraded chain comes out in.
    function test_defaultsToRequiringEverySystem() public view {
        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);
    }

    function test_revertWhen_notEraChain() public {
        utilsFacet.util_setZksyncOS(true);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(MustBeEraChain.selector);
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);
    }

    /// Proof-system policy belongs to the layer the chain settles on. Written anywhere else it would
    /// sit stale and take effect on return.
    function test_revertWhen_notOnTheSettlementLayer() public {
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(NotSettlementLayer.selector);
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);
    }

    /// The kill switch, exercised from a chain that has the lane brought up.
    function test_disablesAirbender() public {
        _readyForTheAirbenderLane();
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(0, AIRBENDER_PROOF_SYSTEM_MASK);
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    function test_disablesBoojum() public {
        _readyForTheAirbenderLane();
        utilsFacet.util_setDisabledProofSystems(0);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), BOOJUM_PROOF_SYSTEM_MASK);
    }

    function test_restoresBothRequired() public {
        _readyForTheAirbenderLane();

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    /// Switching the second one off would leave the chain settling with no proof system at all. One bit
    /// alone cannot say that, so the rule is checked on the mask the call would produce.
    function test_revertWhen_disablingTheSecondSystem() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        uint8 both = BOOJUM_PROOF_SYSTEM_MASK | AIRBENDER_PROOF_SYSTEM_MASK;

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, both));
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, false);
    }

    /// A chain that has settled nothing may still require the lane: its genesis batch is an ordinary
    /// predecessor, opened by the guest the same way the Boojum scheduler opens its own.
    function test_requiresAirbenderBeforeAnyBatchHasSettled() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        assertEq(utilsFacet.util_getTotalBatchesVerified(), 0);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    function test_requiresAirbenderOnceABatchHasSettled() public {
        _readyForTheAirbenderLane();

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    /// Requiring a lane again is the one direction that can strand batches: those committed while it
    /// was off carry a single public input the lane has nothing to read, so the gate refuses them and
    /// the chain stalls behind the oldest. Draining first is the only order that works.
    function test_revertWhen_requiringAirbenderWithUnverifiedBatches() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);
    }

    /// The same guard on the other lane, so it is the enable direction being tested and not the
    /// Airbender bit specifically.
    function test_revertWhen_requiringBoojumWithUnverifiedBatches() public {
        utilsFacet.util_setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_MASK | AIRBENDER_PROOF_SYSTEM_MASK);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 5));
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, true);
    }

    /// Enabling a system that is already on changes nothing, so the drain it would otherwise need does
    /// not apply. Requiring one here would refuse the call that merely restates the chain's own state.
    function test_enablingAnAlreadyEnabledSystemNeedsNoDrain() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK, AIRBENDER_PROOF_SYSTEM_MASK);
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    /// The switch exists for the case where committed batches cannot be proved, so it has to take effect
    /// while those batches are still waiting.
    function test_appliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }
}
