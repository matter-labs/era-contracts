// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, DiamondNotFrozen} from "contracts/common/L1ContractErrors.sol";

contract UnfreezeDiamondTest is AdminTest {
    event Unfreeze();

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        vm.startPrank(nonChainTypeManager);
        adminFacet.unfreezeDiamond();
    }

    function test_revertWhen_diamondIsNotFrozen() public {
        address admin = utilsFacet.util_getChainTypeManager();

        utilsFacet.util_setIsFrozen(false);

        vm.expectRevert(DiamondNotFrozen.selector);

        vm.startPrank(admin);
        adminFacet.unfreezeDiamond();
    }
}
