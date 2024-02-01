// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_GOVERNOR} from "./_Base_Shared.t.sol";

contract OnlyGovernorTest is ZkSyncStateTransitionBaseTest {
    function test_revertWhen_calledByNonGovernor() public {
        address nonGovernor = makeAddr("nonGovernor");

        vm.expectRevert(ERROR_ONLY_GOVERNOR);

        vm.startPrank(nonGovernor);
        testBaseFacet.functionWithOnlyGovernorModifier();
    }

    function test_successfulCall() public {
        address governor = utilsFacet.util_getGovernor();

        vm.startPrank(governor);
        testBaseFacet.functionWithOnlyGovernorModifier();
    }
}
