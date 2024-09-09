// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TransactionFiltererTest} from "./_TransactionFilterer_Shared.t.sol";

import {AlreadyWhitelisted, NotWhitelisted} from "contracts/common/L1ContractErrors.sol";

contract checkTransactionTest is TransactionFiltererTest {
    function test_TransactionAllowedOnlyFromWhitelistedSender() public {
        vm.startPrank(owner);
        bool isTxAllowed = transactionFiltererProxy.isTransactionAllowed(sender, address(0), 0, 0, "0x", address(0)); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, false, "Transaction should not be allowed");

        transactionFiltererProxy.grantWhitelist(sender);
        isTxAllowed = transactionFiltererProxy.isTransactionAllowed(sender, address(0), 0, 0, "0x", address(0)); // Other arguments do not make a difference for the test

        assertEq(isTxAllowed, true, "Transaction should be allowed");
    }
}
