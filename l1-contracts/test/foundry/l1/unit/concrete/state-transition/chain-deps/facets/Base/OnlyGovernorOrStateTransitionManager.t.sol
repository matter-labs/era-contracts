// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyAdminOrChainTypeManagerTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        vm.startPrank(nonAdmin);
        testBaseFacet.functionWithOnlyAdminOrChainTypeManagerModifier();
    }

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        vm.startPrank(nonChainTypeManager);
        testBaseFacet.functionWithOnlyAdminOrChainTypeManagerModifier();
    }

    function test_successfulCallWhenCalledByAdmin() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        testBaseFacet.functionWithOnlyAdminOrChainTypeManagerModifier();
    }

    function test_successfulCallWhenCalledByChainTypeManager() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.startPrank(chainTypeManager);
        testBaseFacet.functionWithOnlyAdminOrChainTypeManagerModifier();
    }
}
