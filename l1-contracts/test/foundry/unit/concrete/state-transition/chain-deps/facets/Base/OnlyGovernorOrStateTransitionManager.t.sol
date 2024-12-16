// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyAdminOrStateTransitionManagerTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        vm.startPrank(nonAdmin);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));
        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithOnlyAdminOrStateTransitionManagerModifier();
    }
}
