// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_BRIDGEHUB} from "./_ZkSyncStateTransitionBase_Shared.t.sol";

contract OnlyBridgehubTest is ZkSyncStateTransitionBaseTest {
    function setUp() public override {
        super.setUp();
        baseFacetWrapper.util_setBridgehub(makeAddr("bridgehub"));
    }

    function test_revertWhen_calledByNonBridgehub() public {
        address nonBridgehub = makeAddr("nonBridgehub");

        vm.expectRevert(ERROR_ONLY_BRIDGEHUB);

        vm.startPrank(nonBridgehub);
        baseFacetWrapper.functionWithOnlyBridgehubModifier();
    }

    function test_successfulCall() public {
        address bridgehub = baseFacetWrapper.util_getBridgehub();

        vm.startPrank(bridgehub);
        baseFacetWrapper.functionWithOnlyBridgehubModifier();
    }
}
