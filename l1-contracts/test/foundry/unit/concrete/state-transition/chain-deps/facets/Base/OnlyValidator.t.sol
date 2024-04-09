// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest, ERROR_ONLY_VALIDATOR} from "./_Base_Shared.t.sol";

contract OnlyValidatorTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        utilsFacet.util_setValidator(nonValidator, false);

        vm.expectRevert(ERROR_ONLY_VALIDATOR);

        vm.startPrank(nonValidator);
        testBaseFacet.functionWithOnlyValidatorModifier();
    }

    function test_successfulCall() public {
        address validator = makeAddr("validator");
        utilsFacet.util_setValidator(validator, true);

        vm.startPrank(validator);
        testBaseFacet.functionWithOnlyValidatorModifier();
    }
}
