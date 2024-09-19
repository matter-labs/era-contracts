// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract SetPendingAdminTest is AdminTest {
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        address newPendingAdmin = makeAddr("newPendingAdmin");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        vm.startPrank(nonAdmin);
        adminFacet.setPendingAdmin(newPendingAdmin);
    }

    function test_successfulCall() public {
        address admin = utilsFacet.util_getAdmin();
        address oldPendingAdmin = utilsFacet.util_getPendingAdmin();
        address newPendingAdmin = makeAddr("newPendingAdmin");

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        vm.startPrank(admin);
        adminFacet.setPendingAdmin(newPendingAdmin);

        assertEq(utilsFacet.util_getPendingAdmin(), newPendingAdmin);
    }
}
