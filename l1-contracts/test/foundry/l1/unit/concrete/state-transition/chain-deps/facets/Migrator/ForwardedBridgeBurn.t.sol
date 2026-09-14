// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {NotCompatibleWithPriorityMode} from "contracts/common/L1ContractErrors.sol";

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
}
