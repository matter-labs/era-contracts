// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @dev Represents a call to be made during multicall.
/// @param target The address to which the call will be made.
/// @param value The amount of Ether (in wei) to be sent along with the call.
/// @param data The calldata to be executed on the `target` address.
struct Call {
    address target;
    uint256 value;
    bytes data;
}
