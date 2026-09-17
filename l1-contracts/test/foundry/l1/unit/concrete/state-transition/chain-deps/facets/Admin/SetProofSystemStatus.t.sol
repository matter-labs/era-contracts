// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {InvalidDisabledProofSystemsMask, MustBeEraChain, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_MASK, BOOJUM_PROOF_SYSTEM_MASK, ProofSystem} from "contracts/common/Config.sol";

contract SetProofSystemStatusTest is AdminTest {
    event NewDisabledProofSystems(uint8 indexed oldDisabledProofSystems, uint8 indexed newDisabledProofSystems);

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

    function test_enablesAirbender() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK, 0);
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    function test_revertWhen_disablingTheSecondSystem() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);
        uint8 both = BOOJUM_PROOF_SYSTEM_MASK | AIRBENDER_PROOF_SYSTEM_MASK;

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, both));
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, false);
    }

    function test_enablingAnAlreadyEnabledSystemIsANoOp() public {
        utilsFacet.util_setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_MASK, AIRBENDER_PROOF_SYSTEM_MASK);
        adminFacet.setProofSystemStatus(ProofSystem.Boojum, true);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);
    }

    /// Takes effect with committed but unproven batches waiting, in both directions.
    function test_appliesWithUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setProofSystemStatus(ProofSystem.Airbender, false);
        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_MASK);

        adminFacet.setProofSystemStatus(ProofSystem.Airbender, true);
        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }
}
