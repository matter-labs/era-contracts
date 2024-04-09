// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBaseTest, ERROR_ONLY_ADMIN} from "./_Base_Shared.t.sol";

contract OnlyAdminTest is ZkSyncHyperchainBaseTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.expectRevert(ERROR_ONLY_ADMIN);

        vm.startPrank(nonAdmin);
        testBaseFacet.functionWithOnlyAdminModifier();
    }

    function test_successfulCall() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        testBaseFacet.functionWithOnlyAdminModifier();
    }
}
