// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyValidatorOrChainTypeManagerTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonValidator() public {
        address nonValidator = makeAddr("nonValidator");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonValidator));

        vm.startPrank(nonValidator);
        testBaseFacet.functionWithOnlyValidatorOrChainTypeManagerModifier();
    }

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        vm.startPrank(nonChainTypeManager);
        testBaseFacet.functionWithOnlyValidatorOrChainTypeManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address validator = makeAddr("validator");
        utilsFacet.util_setValidator(validator, true);

        vm.startPrank(validator);
        testBaseFacet.functionWithOnlyValidatorOrChainTypeManagerModifier();
    }

    function test_successfulCallWhenCalledByChainTypeManager() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.startPrank(chainTypeManager);
        testBaseFacet.functionWithOnlyValidatorOrChainTypeManagerModifier();
    }
}
