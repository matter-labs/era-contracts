// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyAdminTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        vm.startPrank(nonAdmin);
        testBaseFacet.functionWithOnlyAdminModifier();
    }

    function test_successfulCall() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        testBaseFacet.functionWithOnlyAdminModifier();
    }
}
