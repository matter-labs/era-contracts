// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyBridgehubTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonBridgehub() public {
        address nonBridgehub = makeAddr("nonBridgehub");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonBridgehub));
        vm.startPrank(nonBridgehub);
        testBaseFacet.functionWithOnlyBridgehubModifier();
    }

    function test_successfulCall() public {
        address bridgehub = utilsFacet.util_getBridgehub();

        vm.startPrank(bridgehub);
        testBaseFacet.functionWithOnlyBridgehubModifier();
    }
}
