// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyL1InteropCenterTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonL1InteropCenter() public {
        address nonBridgehub = makeAddr("nonBridgehub");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonBridgehub));
        vm.startPrank(nonBridgehub);
        testBaseFacet.functionWithOnlyL1InteropCenterModifier();
    }

    function test_successfulCall() public {
        address bridgehub = dummyBridgehub.interopCenter();

        vm.startPrank(bridgehub);
        testBaseFacet.functionWithOnlyL1InteropCenterModifier();
    }
}
