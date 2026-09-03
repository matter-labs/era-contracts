// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {InvalidDisabledProofSystemsMask, MustBeEraChain, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED, BOOJUM_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Unit tests for the per-chain `disabledProofSystems` setting.
/// @dev Era chains settle behind two independent proof systems. Either may be switched off by the chain
/// admin to keep the chain live through a prover incident, but never both: with both off a batch would
/// settle without being proved at all.
contract SetDisabledProofSystemsTest is AdminTest {
    event NewDisabledProofSystems(uint8 oldDisabledProofSystems, uint8 newDisabledProofSystems);

    function test_defaultsToBothRequired() public view {
        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    function test_revertWhen_notEraChain() public {
        utilsFacet.util_setZksyncOS(true);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(MustBeEraChain.selector);
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    function test_disablesAirbender() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectEmit(true, true, true, true);
        emit NewDisabledProofSystems(0, AIRBENDER_PROOF_SYSTEM_DISABLED);
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }

    function test_disablesBoojum() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setDisabledProofSystems(BOOJUM_PROOF_SYSTEM_DISABLED);

        assertEq(utilsFacet.util_getDisabledProofSystems(), BOOJUM_PROOF_SYSTEM_DISABLED);
    }

    function test_restoresBothRequired() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);
        adminFacet.setDisabledProofSystems(0);

        assertEq(utilsFacet.util_getDisabledProofSystems(), 0);
    }

    /// Disabling everything would leave the chain settling with no proof system at all.
    function test_revertWhen_bothDisabled() public {
        uint8 both = BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED;

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, both));
        adminFacet.setDisabledProofSystems(both);
    }

    /// A mask with bits outside the known set would read as a configured policy while meaning nothing.
    function testFuzz_revertWhen_unknownBitsSet(uint8 _mask) public {
        uint8 known = BOOJUM_PROOF_SYSTEM_DISABLED | AIRBENDER_PROOF_SYSTEM_DISABLED;
        vm.assume(_mask > known);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, _mask));
        adminFacet.setDisabledProofSystems(_mask);
    }

    /// The setting exists for the case where committed batches cannot be proved, so it has to take effect
    /// while those batches are still waiting.
    function test_appliesWithCommittedButUnverifiedBatches() public {
        utilsFacet.util_setTotalBatchesCommitted(5);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setDisabledProofSystems(AIRBENDER_PROOF_SYSTEM_DISABLED);

        assertEq(utilsFacet.util_getDisabledProofSystems(), AIRBENDER_PROOF_SYSTEM_DISABLED);
    }
}
