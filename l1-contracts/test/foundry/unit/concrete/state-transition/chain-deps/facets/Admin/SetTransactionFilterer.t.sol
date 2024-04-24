// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";

contract SetTransactionFiltererTest is AdminTest {
    event NewTransactionFilterer(address oldTransactionFilterer, address newTransactionFilterer);

    function test_initialFilterer() public {
        address admin = utilsFacet.util_getAdmin();
        address transactionFilterer = makeAddr("transactionFilterer");

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewTransactionFilterer(address(0), transactionFilterer);

        vm.startPrank(admin);
        adminFacet.setTransactionFilterer(transactionFilterer);
    }

    function test_replaceFilterer() public {
        address admin = utilsFacet.util_getAdmin();
        address f1 = makeAddr("f1");
        address f2 = makeAddr("f2");
        utilsFacet.util_setTransactionFilterer(f1);

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewTransactionFilterer(f1, f2);

        vm.startPrank(admin);
        adminFacet.setTransactionFilterer(f2);
    }

    function test_revertWhen_notAdmin() public {
        address transactionFilterer = makeAddr("transactionFilterer");

        vm.expectRevert("Hyperchain: not admin");
        vm.startPrank(makeAddr("nonAdmin"));
        adminFacet.setTransactionFilterer(transactionFilterer);
    }
}
