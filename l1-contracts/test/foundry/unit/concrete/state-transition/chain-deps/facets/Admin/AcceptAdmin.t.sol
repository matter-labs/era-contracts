// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract AcceptAdminTest is AdminTest {
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    function test_revertWhen_calledByNonPendingAdmin() public {
        address nonPendingAdmin = makeAddr("nonPendingAdmin");

        vm.startPrank(nonPendingAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonPendingAdmin));
        adminFacet.acceptAdmin();
    }

    function test_successfulCall() public {
        address pendingAdmin = utilsFacet.util_getPendingAdmin();
        address previousAdmin = utilsFacet.util_getAdmin();

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingAdmin(pendingAdmin, address(0));
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewAdmin(previousAdmin, pendingAdmin);

        vm.startPrank(pendingAdmin);
        adminFacet.acceptAdmin();

        assertEq(utilsFacet.util_getPendingAdmin(), address(0));
        assertEq(utilsFacet.util_getAdmin(), pendingAdmin);
    }
}
