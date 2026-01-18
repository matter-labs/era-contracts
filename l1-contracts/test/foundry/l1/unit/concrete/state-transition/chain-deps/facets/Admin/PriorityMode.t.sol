// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {NotCompatibleWithPriorityMode, OnlyPriorityMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {PriorityModeAlreadyAllowed} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract PriorityModeAdminTest is AdminTest {
    function test_revertWhen_permanentlyAllowPriorityMode_calledTwice() public {
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        adminFacet.permanentlyAllowPriorityMode();

        vm.prank(admin);
        vm.expectRevert(PriorityModeAlreadyAllowed.selector);
        adminFacet.permanentlyAllowPriorityMode();
    }

    function test_setPriorityModeTransactionFilterer_updatesPriorityModeFilterer() public {
        address chainTypeManager = makeAddr("chainTypeManager");
        utilsFacet.util_setChainTypeManager(chainTypeManager);

        address filterer = makeAddr("priorityModeFilterer");

        vm.prank(chainTypeManager);
        adminFacet.setPriorityModeTransactionFilterer(filterer);

        assertEq(utilsFacet.util_getPriorityModeTransactionFilterer(), filterer);
        assertEq(utilsFacet.util_getTransactionFilterer(), address(0));
    }

    function test_setPriorityModeTransactionFilterer_updatesTransactionFiltererWhenAllowed() public {
        address admin = utilsFacet.util_getAdmin();
        address chainTypeManager = makeAddr("chainTypeManager");
        utilsFacet.util_setChainTypeManager(chainTypeManager);

        vm.prank(admin);
        adminFacet.permanentlyAllowPriorityMode();

        address filterer = makeAddr("priorityModeFilterer");

        vm.prank(chainTypeManager);
        adminFacet.setPriorityModeTransactionFilterer(filterer);

        assertEq(utilsFacet.util_getPriorityModeTransactionFilterer(), filterer);
        assertEq(utilsFacet.util_getTransactionFilterer(), filterer);
    }

    function test_permanentlyAllowPriorityMode_usesPriorityModeFilterer() public {
        address admin = utilsFacet.util_getAdmin();
        address chainTypeManager = makeAddr("chainTypeManager");
        utilsFacet.util_setChainTypeManager(chainTypeManager);

        address filterer = makeAddr("priorityModeFilterer");
        vm.prank(chainTypeManager);
        adminFacet.setPriorityModeTransactionFilterer(filterer);

        vm.prank(admin);
        adminFacet.permanentlyAllowPriorityMode();

        assertEq(utilsFacet.util_getPriorityModeTransactionFilterer(), filterer);
        assertEq(utilsFacet.util_getTransactionFilterer(), filterer);
    }

    function test_revertWhen_setPriorityModeTransactionFilterer_notChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.prank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setPriorityModeTransactionFilterer(makeAddr("filterer"));
    }

    function test_revertWhen_deactivatePriorityMode_notActive() public {
        address chainTypeManager = makeAddr("chainTypeManager");
        utilsFacet.util_setChainTypeManager(chainTypeManager);

        vm.prank(chainTypeManager);
        vm.expectRevert(OnlyPriorityMode.selector);
        adminFacet.deactivatePriorityMode();
    }

    function test_deactivatePriorityMode_success() public {
        address chainTypeManager = makeAddr("chainTypeManager");
        utilsFacet.util_setChainTypeManager(chainTypeManager);
        utilsFacet.util_setPriorityModeActivated(true);

        vm.prank(chainTypeManager);
        adminFacet.deactivatePriorityMode();

        assertFalse(utilsFacet.util_getPriorityModeActivated());
    }
}
