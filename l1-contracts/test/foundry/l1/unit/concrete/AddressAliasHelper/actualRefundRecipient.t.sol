// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";

// Used to test when recipient is a contract
contract TestContract {
    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract ActualRefundRecipient is AddressAliasHelperSharedTest {
    /// @notice Mirrors the composition performed in the Mailbox: a finalized recipient is used as is,
    /// otherwise the explicit-recipient aliasing is applied with the given EIP-7702 flag.
    function _composeAsMailbox(
        address recipient,
        address prevMessageSender,
        bool is7702Recipient
    ) internal view returns (address) {
        (address resolved, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            recipient,
            prevMessageSender
        );
        return aliasingFinalized ? resolved : addressAliasHelper.applyRefundRecipientAlias(resolved, is7702Recipient);
    }

    function test_When_recipientAddressIsNotZero() public {
        address recipient = makeAddr("recipient");
        address prevMessageSender = makeAddr("prevMessageSender");

        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            recipient,
            prevMessageSender
        );

        // An explicit recipient is passed through unresolved: it may still need the Mailbox aliasing.
        assertEq(actualRecipient, recipient);
        assertFalse(aliasingFinalized);
    }

    function test_When_recipientAddressIsZeroAndTxOriginIsPrevMsgSender() public {
        address recipient = address(0);
        address prevMessageSender = makeAddr("prevMessageSender");

        vm.startBroadcast(prevMessageSender);
        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            recipient,
            prevMessageSender
        );
        vm.stopBroadcast();

        // An EOA caller controls the same address on L2: final, no aliasing.
        assertEq(actualRecipient, prevMessageSender);
        assertTrue(aliasingFinalized);
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

        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            recipient,
            prevMessageSender
        );

        assertEq(actualRecipient, expectedRecipient);
        assertTrue(aliasingFinalized);
    }

    // A caller with deployed code is not resolved here: only the Mailbox can distinguish an EIP-7702
    // account from a regular contract, so the aliasing is deferred to `applyRefundRecipientAlias`.
    function test_When_recipientAddressIsZeroAndPrevMsgSenderIsDeployedContract() public {
        address recipient = address(0);
        address prevMessageSender = address(new TestContract());

        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            recipient,
            prevMessageSender
        );

        assertEq(actualRecipient, prevMessageSender);
        assertFalse(aliasingFinalized);
    }

    // Pins that `aliasingFinalized` prevents a double alias: even if a contract happens to be deployed
    // at the alias of a constructor caller, the Mailbox composition must not alias the resolved
    // recipient a second time.
    function test_Composition_When_constructorCallerWithCodeAtAlias_NoDoubleAlias() public {
        address prevMessageSender = makeAddr("prevMessageSender");
        address aliased = addressAliasHelper.applyL1ToL2Alias(prevMessageSender);
        vm.etch(aliased, hex"6000");

        (address resolved, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            address(0),
            prevMessageSender
        );
        assertEq(resolved, aliased);
        assertTrue(aliasingFinalized);

        assertEq(_composeAsMailbox(address(0), prevMessageSender, false), aliased);
    }

    // The composition cases below replicate the semantics of the removed `actualRefundRecipientMailbox`
    // zero branch through `actualRefundRecipient` + `applyRefundRecipientAlias`, as composed in the Mailbox.

    function test_Composition_When_recipientIsZeroAndTxOriginEqualsPrevMsgSender() public {
        address prevMessageSender = makeAddr("prevMessageSender");

        vm.startBroadcast(prevMessageSender);
        address actualRecipient = _composeAsMailbox(address(0), prevMessageSender, false);
        vm.stopBroadcast();

        assertEq(actualRecipient, prevMessageSender);
    }

    function test_Composition_When_recipientIsZeroAndTxOriginDiffersAndSenderIsNot7702() public {
        address prevMessageSender = address(new TestContract());

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(prevMessageSender);

        assertEq(_composeAsMailbox(address(0), prevMessageSender, false), expectedRecipient);
    }

    // An EIP-7702 sender carries designator code on L1, so the resolution is deferred to the Mailbox,
    // whose 7702 check then exempts it from aliasing.
    function test_Composition_When_recipientIsZeroAndSenderIs7702Account() public {
        address prevMessageSender = makeAddr("prevMessageSender");
        vm.etch(prevMessageSender, abi.encodePacked(hex"ef0100", makeAddr("delegate")));

        assertEq(_composeAsMailbox(address(0), prevMessageSender, true), prevMessageSender);
    }

    function test_Composition_When_recipientIsContract() public {
        address recipient = address(new TestContract());
        address prevMessageSender = makeAddr("prevMessageSender");

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(recipient);

        assertEq(_composeAsMailbox(recipient, prevMessageSender, false), expectedRecipient);
    }

    // An explicit EOA recipient must be left unaliased.
    function test_Composition_When_recipientIsEOA() public {
        address recipient = makeAddr("recipient");
        address prevMessageSender = address(new TestContract());

        assertEq(_composeAsMailbox(recipient, prevMessageSender, false), recipient);
    }

    // ============ Fuzz Tests ============

    // A codeless non-tx.origin caller (constructor case) always resolves to its finalized alias.
    function testFuzz_zeroRecipient_constructorCallerAliasedAndFinalized(address caller) public {
        // solhint-disable-next-line avoid-tx-origin
        vm.assume(caller != tx.origin);
        vm.assume(caller.code.length == 0);

        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(
            address(0),
            caller
        );

        assertEq(actualRecipient, addressAliasHelper.applyL1ToL2Alias(caller));
        assertTrue(aliasingFinalized);
    }

    // An explicit recipient is always passed through unresolved, regardless of the caller.
    function testFuzz_explicitRecipient_passedThroughUnfinalized(address recipient, address caller) public {
        vm.assume(recipient != address(0));

        (address actualRecipient, bool aliasingFinalized) = addressAliasHelper.actualRefundRecipient(recipient, caller);

        assertEq(actualRecipient, recipient);
        assertFalse(aliasingFinalized);
    }
}
