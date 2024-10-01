// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract FreezeDiamondTest is AdminTest {
    event Freeze();

    function test_revertWhen_calledByNonStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonStateTransitionManager));

        vm.startPrank(nonStateTransitionManager);
        adminFacet.freezeDiamond();
    }

    function test_SuccessfulFreeze() public {
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit Freeze();

        vm.startPrank(utilsFacet.util_getStateTransitionManager());
        adminFacet.freezeDiamond();
    }
}
