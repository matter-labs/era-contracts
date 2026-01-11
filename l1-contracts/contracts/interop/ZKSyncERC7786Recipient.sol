// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC7786Recipient} from "./IERC7786Recipient.sol";
import {L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @title ZKSyncERC7786Recipient
/// @notice Abstract contract that implements IERC7786Recipient with access control
/// @dev Inheritors must implement the _receiveMessage internal function
abstract contract ZKSyncERC7786Recipient is IERC7786Recipient {
    /// @notice Thrown when the caller is not the interop handler
    error OnlyInteropHandler(address sender);

    /// @notice Ensures that only the L2 Interop Handler can call the function
    modifier onlyInteropHandler() {
        if (msg.sender != L2_INTEROP_HANDLER_ADDR) {
            revert OnlyInteropHandler(msg.sender);
        }
        _;
    }

    /// @inheritdoc IERC7786Recipient
    function receiveMessage(
        bytes32 _receiveId,
        bytes calldata _sender,
        bytes calldata _payload
    ) external payable onlyInteropHandler returns (bytes4) {
        return _receiveMessage(_receiveId, _sender, _payload);
    }

    /// @notice Internal function to handle the message logic
    /// @param _receiveId Unique identifier for the message
    /// @param _sender ERC-7930 encoded sender address
    /// @param _payload Message payload
    /// @return The function selector to confirm successful handling
    function _receiveMessage(
        bytes32 _receiveId,
        bytes calldata _sender,
        bytes calldata _payload
    ) internal virtual returns (bytes4);
}
