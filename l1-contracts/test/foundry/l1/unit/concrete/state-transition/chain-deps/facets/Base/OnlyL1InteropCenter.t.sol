// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBaseTest} from "./_Base_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract OnlyL1InteropCenterTest is ZKChainBaseTest {
    function test_revertWhen_calledByNonInteropCenter() public {
        address nonInteropCenter = makeAddr("nonInteropCenter");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonInteropCenter));
        vm.startPrank(nonInteropCenter);
        testBaseFacet.functionWithOnlyL1InteropCenterModifier();
    }

    function test_revertWhen_calledByBridgehubItself() public {
        // The interop center is resolved through the bridgehub, but the bridgehub itself is not
        // allowed to call the gated function once a distinct interop center is set.
        address l1InteropCenter = makeAddr("l1InteropCenter");
        dummyBridgehub.setInteropCenter(l1InteropCenter);

        address bridgehub = utilsFacet.util_getBridgehub();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bridgehub));
        vm.startPrank(bridgehub);
        testBaseFacet.functionWithOnlyL1InteropCenterModifier();
    }

    function test_successfulCall() public {
        address l1InteropCenter = makeAddr("l1InteropCenter");
        dummyBridgehub.setInteropCenter(l1InteropCenter);

        vm.startPrank(l1InteropCenter);
        testBaseFacet.functionWithOnlyL1InteropCenterModifier();
    }
}
