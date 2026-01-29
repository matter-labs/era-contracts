// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";

contract AddressAliasHelperTest {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function applyL1ToL2Alias(address _l1Address) external pure returns (address) {
        return AddressAliasHelper.applyL1ToL2Alias(_l1Address);
    }

    function undoL1ToL2Alias(address _l2Address) external pure returns (address) {
        return AddressAliasHelper.undoL1ToL2Alias(_l2Address);
    }

    function actualRefundRecipient(address _recipient, address _prevMessageSender) external view returns (address) {
        return AddressAliasHelper.actualRefundRecipient(_recipient, _prevMessageSender);
    }

    function actualRefundRecipientMailbox(
        address _recipient,
        address _prevMessageSender,
        bool _is7702AccountRefundRecipient,
        bool _is7702AccountSender
    ) external view returns (address) {
        return
            AddressAliasHelper.actualRefundRecipientMailbox(
                _recipient,
                _prevMessageSender,
                _is7702AccountRefundRecipient,
                _is7702AccountSender
            );
    }
}
