// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyChainTypeManagerTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        vm.startPrank(nonChainTypeManager);
        testBaseFacet.functionWithOnlyChainTypeManagerModifier();
    }

    function test_successfulCall() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.startPrank(chainTypeManager);
        testBaseFacet.functionWithOnlyChainTypeManagerModifier();
    }
}
