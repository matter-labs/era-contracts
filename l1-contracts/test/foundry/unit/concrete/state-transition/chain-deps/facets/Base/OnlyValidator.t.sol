// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyValidatorTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        utilsFacet.util_setValidator(nonValidator, false);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonValidator));
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
