// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionBaseTest, ERROR_ONLY_VALIDATOR} from "./_ZkSyncStateTransitionBase_Shared.t.sol";

contract OnlyValidatorTest is ZkSyncStateTransitionBaseTest {
    address validator = makeAddr("validator");

    function setUp() public override {
        super.setUp();
        baseFacetWrapper.util_setValidatorStatus(validator, true);
    }

    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        baseFacetWrapper.util_setValidatorStatus(nonValidator, false);

        vm.expectRevert(ERROR_ONLY_VALIDATOR);

        vm.startPrank(nonValidator);
        baseFacetWrapper.functionWithOnlyValidatorModifier();
    }

    function test_successfulCall() public {
        vm.startPrank(validator);
        baseFacetWrapper.functionWithOnlyValidatorModifier();
    }
}
