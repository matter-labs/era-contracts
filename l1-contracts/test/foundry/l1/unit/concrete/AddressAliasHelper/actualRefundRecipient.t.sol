// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";
import {Test} from "forge-std/Test.sol";

// Used to test when recipient is a contract
contract TestContract {
    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract ActualRefundRecipient is AddressAliasHelperSharedTest {
    function test_When_recipientAddressIsNotZero() public {
        address recipient = makeAddr("recipient");
        address prevMessageSender = makeAddr("prevMessageSender");

        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);

        assertEq(actualRecipient, recipient);
    }

    function test_When_recipientAddressIsZeroAndTxOriginIsPrevMsgSender() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        vm.startBroadcast(prevMessageSender);
        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);
        vm.stopBroadcast();

        assertEq(actualRecipient, prevMessageSender);
    }

    function test_When_recipientAddressIsZeroAndTxOriginIsNotPrevMsgSender() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(prevMessageSender);

        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);

        assertEq(actualRecipient, expectedRecipient);
    }

    function test_When_recipientIsContract() public {
        address recipient = address(new TestContract());
        address prevMessageSender = makeAddr("prevMessageSender");

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(recipient);

        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);

        assertEq(actualRecipient, expectedRecipient);
    }
}
