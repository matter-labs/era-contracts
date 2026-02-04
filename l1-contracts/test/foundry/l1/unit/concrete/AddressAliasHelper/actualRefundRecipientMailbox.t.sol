// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";
import {Test} from "forge-std/Test.sol";

// Used to test when recipient is a contract
contract TestContract7702 {
    // add this to be excluded from coverage report
    function test() internal virtual {}
}

/// @notice Tests for actualRefundRecipientMailbox with EIP-7702 account scenarios
contract ActualRefundRecipientMailboxTest is AddressAliasHelperSharedTest {
    /// @notice When recipient is zero, tx.origin equals prevMsgSender, no aliasing occurs
    function test_When_recipientIsZeroAndTxOriginEqualsPrevMsgSender() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        vm.startBroadcast(prevMessageSender);
        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            false
        );
        vm.stopBroadcast();

        assertEq(actualRecipient, prevMessageSender);
    }

    /// @notice When recipient is zero and sender is 7702 account, no aliasing occurs
    function test_When_recipientIsZeroAndSenderIs7702Account() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        // When _is7702AccountSender is true, no aliasing should occur
        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            true // is7702AccountSender = true
        );

        // Should return prevMessageSender without aliasing
        assertEq(actualRecipient, prevMessageSender);
    }

    /// @notice When recipient is zero, tx.origin differs from prevMsgSender, and sender is not 7702, alias is applied
    function test_When_recipientIsZeroAndTxOriginDiffersAndSenderIsNot7702() public {
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

    /// @notice When recipient is an EOA (no code), no aliasing
    function test_When_recipientIsEOA() public {
        address recipient = makeAddr("recipient");
        address prevMessageSender = makeAddr("prevMessageSender");

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            false
        );

        assertEq(actualRecipient, recipient);
    }

    /// @notice When recipient is contract and not 7702, aliasing is applied
    function test_When_recipientIsContractAndNot7702() public {
        address recipient = address(new TestContract7702());
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

    /// @notice When recipient is contract but is 7702 account, no aliasing
    function test_When_recipientIsContractAnd7702Account() public {
        address recipient = address(new TestContract7702());
        address prevMessageSender = makeAddr("prevMessageSender");

        // When _is7702AccountRefundRecipient is true, should not alias even for contracts
        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            true, // is7702AccountRefundRecipient = true
            false
        );

        // Should return recipient without aliasing
        assertEq(actualRecipient, recipient);
    }

    /// @notice Both flags true - 7702 sender and 7702 recipient
    function test_When_both7702Flags() public {
        address recipient = address(new TestContract7702());
        address prevMessageSender = makeAddr("prevMessageSender");

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            true, // is7702AccountRefundRecipient = true
            true // is7702AccountSender = true
        );

        // Should return recipient without aliasing
        assertEq(actualRecipient, recipient);
    }

    /// @notice When recipient is zero, both 7702 flags true
    function test_When_recipientZeroAndBoth7702Flags() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            true,
            true // is7702AccountSender = true means no aliasing
        );

        // Should return prevMessageSender without aliasing
        assertEq(actualRecipient, prevMessageSender);
    }

    // ============ Fuzz Tests ============

    function testFuzz_recipientNotZero_EOA(address recipient, address prevMessageSender) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0);

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            false
        );

        // EOA recipients should not be aliased
        assertEq(actualRecipient, recipient);
    }

    function testFuzz_recipientNotZero_7702Account(address recipient, address prevMessageSender) public {
        vm.assume(recipient != address(0));

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            true, // marked as 7702 account
            false
        );

        // 7702 account recipients should not be aliased
        assertEq(actualRecipient, recipient);
    }

    function testFuzz_7702Sender_noAlias(address prevMessageSender) public {
        address recipient = address(0);

        address actualRecipient = addressAliasHelper.actualRefundRecipientMailbox(
            recipient,
            prevMessageSender,
            false,
            true // is7702AccountSender = true
        );

        // 7702 sender should not trigger aliasing
        assertEq(actualRecipient, prevMessageSender);
    }
}
