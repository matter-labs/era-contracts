// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {NotCompatibleWithPriorityMode} from "contracts/common/L1ContractErrors.sol";

contract ForwardedBridgeBurnAdminTest is AdminTest {
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
        adminFacet.forwardedBridgeBurn(address(0), address(0), "");
    }
}
