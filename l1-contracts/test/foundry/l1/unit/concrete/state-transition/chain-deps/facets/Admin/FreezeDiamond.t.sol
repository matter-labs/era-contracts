// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract FreezeDiamondTest is AdminTest {
    event Freeze();

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        vm.startPrank(nonChainTypeManager);
        adminFacet.freezeDiamond();
    }

    function test_SuccessfulFreeze() public {
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit Freeze();

        vm.startPrank(utilsFacet.util_getChainTypeManager());
        adminFacet.freezeDiamond();
    }
}
