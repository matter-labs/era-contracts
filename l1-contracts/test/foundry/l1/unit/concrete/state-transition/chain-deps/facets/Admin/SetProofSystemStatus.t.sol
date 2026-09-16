// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {InvalidDisabledProofSystemsMask, MustBeEraChain, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_MASK, BOOJUM_PROOF_SYSTEM_MASK, ProofSystem} from "contracts/common/Config.sol";

/// @notice Unit tests for `setProofSystemStatus`, which turns one of the chain's proof systems on or off.
/// @dev Era chains settle behind two independent proof systems. Either may be switched off by the chain
/// admin to keep the chain live through a prover incident, but never both: with both off a batch would
/// settle without being proved at all. One system per call, so the never-both rule is a check on what the
/// pair becomes rather than on the argument.
contract SetProofSystemStatusTest is AdminTest {
    event NewDisabledProofSystems(uint8 indexed oldDisabledProofSystems, uint8 indexed newDisabledProofSystems);

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

    function test_disablesAirbender() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(0, AIRBENDER_PROOF_SYSTEM_MASK);
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    function test_disablesBoojum() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), BOOJUM_PROOF_SYSTEM_MASK);
    }

    function test_restoresBothRequired() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK, 0);
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

    /// Restating the chain's own state changes nothing and is not an error.
    function test_enablingAnAlreadyEnabledSystemIsANoOp() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK, AIRBENDER_PROOF_SYSTEM_MASK);
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    /// The switch exists for the case where committed batches cannot be proved, so it has to take effect
    /// while those batches are still waiting.
    function test_disablingAppliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    /// Every batch carries both commitments whatever the mask was when it was committed, so re-enabling
    /// a system needs no drained pipeline: the waiting batches are provable on it if the operator
    /// supplied correct data while it was off.
    function test_enablingAppliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }
}
