// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyStateTransitionManagerTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));
        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithOnlyStateTransitionManagerModifier();
    }

    function test_successfulCall() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithOnlyStateTransitionManagerModifier();
    }
}
