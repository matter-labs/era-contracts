// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

struct InteropCall {
    address to;
    bytes data;
    uint256 value;
}

interface IInteropHandler {
    function executePaymasterBundle(bytes calldata _message) external;
}
