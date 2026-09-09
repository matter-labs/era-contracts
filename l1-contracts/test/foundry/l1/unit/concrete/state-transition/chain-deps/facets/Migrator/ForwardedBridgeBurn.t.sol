// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {MultiProofChainCannotMigrate, NotCompatibleWithPriorityMode} from "contracts/common/L1ContractErrors.sol";

contract ForwardedBridgeBurnMigratorTest is MigratorTest {
    function test_revertWhen_forwardedBridgeBurn_priorityModeAllowed() public {
        address chainAssetHandler = makeAddr("chainAssetHandler");
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandler)
        );
        utilsFacet.util_setPriorityModeCanBeActivated(true);

        vm.prank(chainAssetHandler);
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        migratorFacet.forwardedBridgeBurn(address(0), address(0), "");
    }

    /// The multi-proof settings are not carried in `ZKChainCommitment`, so a chain that migrated while
    /// they were set would be re-initialised single-proof on the destination: settling behind Boojum
    /// alone, silently, while its sequencer kept committing Airbender data the destination refuses.
    /// The capability has to be withdrawn deliberately first.
    function test_revertWhen_forwardedBridgeBurn_multiProofEnabled() public {
        address chainAssetHandler = makeAddr("chainAssetHandler");
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandler)
        );
        utilsFacet.util_setMultiProofEnabled(true);
        // Read before arming the cheatcode: an argument evaluated afterwards is itself a call, and
        // `expectRevert` would match that instead of the one under test.
        address chainAdmin = utilsFacet.util_getAdmin();

        vm.prank(chainAssetHandler);
        vm.expectRevert(MultiProofChainCannotMigrate.selector);
        migratorFacet.forwardedBridgeBurn(address(0), chainAdmin, "");
    }
}
