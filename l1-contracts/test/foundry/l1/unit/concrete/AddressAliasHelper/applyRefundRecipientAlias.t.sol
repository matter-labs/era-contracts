// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";

// Used to test when recipient is a contract
contract TestContract7702 {
    // add this to be excluded from coverage report
    function test() internal virtual {}
}

/// @notice Tests for applyRefundRecipientAlias, the Mailbox-side aliasing of a refund recipient whose
/// aliasing was not finalized by `actualRefundRecipient` (explicit recipients and deployed-code callers).
contract ApplyRefundRecipientAliasTest is AddressAliasHelperSharedTest {
    /// @notice When recipient is an EOA (no code), no aliasing
    function test_When_recipientIsEOA() public {
        address recipient = makeAddr("recipient");

        address actualRecipient = addressAliasHelper.applyRefundRecipientAlias(recipient, false);

        assertEq(actualRecipient, recipient);
    }

    /// @notice When recipient is contract and not 7702, aliasing is applied
    function test_When_recipientIsContractAndNot7702() public {
        address recipient = address(new TestContract7702());

        address expectedRecipient = addressAliasHelper.applyL1ToL2Alias(recipient);

        address actualRecipient = addressAliasHelper.applyRefundRecipientAlias(recipient, false);

        assertEq(actualRecipient, expectedRecipient);
    }

    /// @notice When recipient is contract but is 7702 account, no aliasing
    function test_When_recipientIsContractAnd7702Account() public {
        address recipient = address(new TestContract7702());

        address actualRecipient = addressAliasHelper.applyRefundRecipientAlias(recipient, true);

        assertEq(actualRecipient, recipient);
    }

    // ============ Fuzz Tests ============

    function testFuzz_recipient_EOA(address recipient) public {
        vm.assume(recipient.code.length == 0);

        address actualRecipient = addressAliasHelper.applyRefundRecipientAlias(recipient, false);

        // EOA recipients should not be aliased
        assertEq(actualRecipient, recipient);
    }

    function testFuzz_recipient_7702Account(address recipient) public {
        address actualRecipient = addressAliasHelper.applyRefundRecipientAlias(recipient, true);

        // 7702 account recipients should not be aliased
        assertEq(actualRecipient, recipient);
    }
}
