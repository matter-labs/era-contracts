// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";

contract AcceptGovernorTest is AdminTest {
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    function setUp() public override {
        super.setUp();
        adminFacetWrapper.util_setPendingGovernor(makeAddr("pendingGovernor"));
    }

    function test_revertWhen_calledByNonPendingGovernor() public {
        address nonPendingGovernor = makeAddr("nonPendingGovernor");

        vm.expectRevert(bytes.concat("n4"));

        vm.startPrank(nonPendingGovernor);
        adminFacet.acceptGovernor();
    }

    function test_successfulCall() public {
        address pendingGovernor = adminFacetWrapper.util_getPendingGovernor();
        address previousGovernor = adminFacetWrapper.util_getGovernor();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingGovernor(pendingGovernor, address(0));
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewGovernor(previousGovernor, pendingGovernor);

        vm.startPrank(pendingGovernor);
        adminFacet.acceptGovernor();

        assertEq(adminFacetWrapper.util_getPendingGovernor(), address(0));
        assertEq(adminFacetWrapper.util_getGovernor(), pendingGovernor);
    }
}
