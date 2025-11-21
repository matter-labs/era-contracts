// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC7786Recipient} from "../../interop/IERC7786Recipient.sol";

contract DummyInteropRecipient is IERC7786Recipient {
    bytes4 public selector;
    function receiveMessage(
        bytes32 receiveId, // Unique identifier
        bytes calldata sender, // ERC-7930 address
        bytes calldata payload
    ) external payable returns (bytes4) {
        return IERC7786Recipient.receiveMessage.selector;
    }

    function callSelf() external payable {
        selector = this.receiveMessage(bytes32(0), bytes("0x"), bytes("0x"));
    }
}
