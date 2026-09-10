// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2019-2021, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

library AddressAliasHelper {
    // solhint-disable-next-line const-name-snakecase
    uint160 private constant offset = uint160(0x1111000000000000000000000000000000001111);

    /// @notice Utility function converts the address that submitted a tx
    /// to the inbox on L1 to the msg.sender viewed on L2
    /// @param l1Address the address in the L1 that triggered the tx to L2
    /// @return l2Address L2 address as viewed in msg.sender
    function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + offset);
        }
    }

    /// @notice Utility function that converts the msg.sender viewed on L2 to the
    /// address that submitted a tx to the inbox on L1
    /// @param l2Address L2 address as viewed in msg.sender
    /// @return l1Address the address in the L1 that triggered the tx to L2
    function undoL1ToL2Alias(address l2Address) internal pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - offset);
        }
    }

    /// @notice Utility function used to resolve an unset refund recipient to the original caller's L2 identity.
    /// The resolution rules are described in {protocol-docs/bridging.md}.
    /// @param _refundRecipient the address that should receive the refund, or zero if unset
    /// @param _originalCaller the address that triggered the tx to L2
    /// @return _recipient the resolved refund recipient
    /// @return _aliasingFinalized true if `_recipient` needs no further aliasing; when false, the Mailbox
    /// must finish the aliasing via `applyRefundRecipientAlias`
    function actualRefundRecipient(
        address _refundRecipient,
        address _originalCaller
    ) internal view returns (address _recipient, bool _aliasingFinalized) {
        if (_refundRecipient != address(0)) {
            // An explicitly provided recipient may still be a contract that needs to be aliased.
            return (_refundRecipient, false);
        }
        // If the `_refundRecipient` is not provided, we use the `_originalCaller` as the recipient.
        // solhint-disable avoid-tx-origin
        // slither-disable-next-line tx-origin
        if (_originalCaller == tx.origin) {
            // The caller is an EOA, which controls the same address on L2.
            return (_originalCaller, true);
        }
        // solhint-enable avoid-tx-origin
        if (_originalCaller.code.length != 0) {
            // IMPORTANT: callers with deployed code are left as is — the Mailbox is still expected to finish
            // the aliasing via `applyRefundRecipientAlias`. The reason is that only the Mailbox has the
            // ability to check whether an account is an EIP-7702 one (and so must be exempted from aliasing);
            // this helper cannot make that distinction, as EIP-7702 accounts also have non-empty code.
            return (_originalCaller, false);
        }
        // A caller without deployed code that is not the tx originator (i.e. a contract calling from its
        // constructor) is an L1 contract that only controls its aliased address on L2. It cannot be an
        // EIP-7702 account (those carry non-empty code), so the aliasing is final and must not be applied
        // a second time even if a contract happens to exist at the aliased address.
        return (AddressAliasHelper.applyL1ToL2Alias(_originalCaller), true);
    }

    /// @notice Utility function used to apply the L1 -> L2 alias to a refund recipient whose aliasing was
    /// not finalized by `actualRefundRecipient` (only to be used in Mailbox)
    /// @param _refundRecipient the address that should receive the refund
    /// @param _is7702AccountRefundRecipient true, if the _refundRecipient is EIP 7702 Account
    /// @return _recipient the corrected address that should receive the refund
    function applyRefundRecipientAlias(
        address _refundRecipient,
        bool _is7702AccountRefundRecipient
    ) internal view returns (address _recipient) {
        // If the `_refundRecipient` is a smart contract, we apply the L1 to L2 alias to prevent foot guns.
        // Also we check that refund recipient is not EIP7702 account, as this would result in incorrect aliasing
        _recipient = (_refundRecipient.code.length == 0 || _is7702AccountRefundRecipient)
            ? _refundRecipient
            : AddressAliasHelper.applyL1ToL2Alias(_refundRecipient);
    }
}
