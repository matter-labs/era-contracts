// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC7786Recipient} from "../../interop/IERC7786Recipient.sol";

contract DummyInteropRecipient is IERC7786Recipient {
    bytes4 public selector;

    // Allow the contract to receive ETH
    receive() external payable {}

    // This contract's ABI is exported to zkstack-out, so the parameter names are part of a
    // published interface and are kept even though the body ignores them.
    // solhint-disable no-unused-vars
    function receiveMessage(
        bytes32 receiveId, // Unique identifier
        bytes calldata sender, // ERC-7930 address
        bytes calldata payload
    ) external payable returns (bytes4) {
        // solhint-enable no-unused-vars
        return IERC7786Recipient.receiveMessage.selector;
    }

    function callSelf() external payable {
        selector = this.receiveMessage(bytes32(0), bytes("0x"), bytes("0x"));
    }
}
