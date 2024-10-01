// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyValidatorOrStateTransitionManagerTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonValidator));

        vm.startPrank(nonValidator);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));

        vm.startPrank(nonStateTransitionManager);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address validator = makeAddr("validator");
        utilsFacet.util_setValidator(validator, true);

        vm.startPrank(validator);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }

    function test_successfulCallWhenCalledByStateTransitionManager() public {
        address stateTransitionManager = utilsFacet.util_getStateTransitionManager();

        vm.startPrank(stateTransitionManager);
        testBaseFacet.functionWithonlyValidatorOrStateTransitionManagerModifier();
    }
}
