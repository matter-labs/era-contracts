// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    // Models a caller whose code is not yet deployed (e.g. a contract calling from its own constructor):
    // the default refund recipient must be aliased, matching the sender aliasing applied in the Mailbox.
    function test_When_recipientAddressIsZeroAndPrevMsgSenderHasNoCodeAndIsNotTxOrigin() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");
        // solhint-disable-next-line avoid-tx-origin
        assertNotEq(tx.origin, prevMessageSender);
        assertEq(prevMessageSender.code.length, 0);

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(prevMessageSender);

        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);

        assertEq(actualRecipient, expectedRecipient);
    }

    // A caller with deployed code is left unaliased here: the Mailbox applies the alias to it
    // via the `code.length` check in `actualRefundRecipientMailbox`.
    function test_When_recipientAddressIsZeroAndPrevMsgSenderIsDeployedContract() public {
        address recipient = address(0);
        address prevMessageSender = address(new TestContract());

        address actualRecipient = addressAliasHelper.actualRefundRecipient(recipient, prevMessageSender);

        assertEq(actualRecipient, prevMessageSender);
    }

    function test_When_recipientAddressIsZeroAndTxOriginIsNotPrevMsgSender() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(prevMessageSender);

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            false
        );

        assertEq(actualRecipient, expectedRecipient);
    }

    function test_When_recipientIsContract() public {
        address recipient = address(new TestContract());
        address prevMessageSender = makeAddr("prevMessageSender");

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(recipient);

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            false
        );

        assertEq(actualRecipient, expectedRecipient);
    }
}
