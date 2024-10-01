// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyBaseTokenBridge is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonBaseTokenBridge() public {
        address nonBaseTokenBridge = makeAddr("nonBaseTokenBridge");

        vm.startPrank(nonBaseTokenBridge);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonBaseTokenBridge));
        testBaseFacet.functionWithOnlyBaseTokenBridgeModifier();
    }

    function test_successfulCall() public {
        address baseTokenBridge = utilsFacet.util_getBaseTokenBridge();

        vm.startPrank(baseTokenBridge);
        testBaseFacet.functionWithOnlyBaseTokenBridgeModifier();
    }
}
