// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {NotCompatibleWithPriorityMode} from "contracts/common/L1ContractErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract ForwardedBridgeBurnMigratorTest is MigratorTest {
    function test_revertWhen_forwardedBridgeBurn_priorityModeAllowed() public {
        // Use the real chainAssetHandler from the deployed Bridgehub — no mock needed
        address realChainAssetHandler = address(IBridgehubBase(address(dummyBridgehub)).chainAssetHandler());
        utilsFacet.util_setPriorityModeCanBeActivated(true);

        vm.prank(realChainAssetHandler);
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        migratorFacet.forwardedBridgeBurn(address(0), address(0), "");
    }
}
