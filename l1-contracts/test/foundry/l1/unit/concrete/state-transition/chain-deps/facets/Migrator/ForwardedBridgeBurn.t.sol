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

    /// `disabledProofSystems` is not carried in `ZKChainCommitment` and the destination initialises
    /// Era chains with the Airbender lane masked, so migrating from any other posture would silently
    /// change which proof systems the chain settles behind.
    function test_revertWhen_forwardedBridgeBurn_airbenderLaneRequired() public {
        address chainAssetHandler = makeAddr("chainAssetHandler");
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandler)
        );
        utilsFacet.util_setDisabledProofSystems(0);
        // Read before arming the cheatcode: an argument evaluated afterwards is itself a call, and
        // `expectRevert` would match that instead of the one under test.
        address chainAdmin = utilsFacet.util_getAdmin();

        vm.prank(chainAssetHandler);
        vm.expectRevert(MultiProofChainCannotMigrate.selector);
        migratorFacet.forwardedBridgeBurn(address(0), chainAdmin, "");
    }
}
