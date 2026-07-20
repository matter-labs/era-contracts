// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL2ToL1Messenger
/// @notice Minimal L2-to-L1 messenger mock for testing: hashes the message and emits the event.
contract MockL2ToL1Messenger {
    /// @notice Matches IL1Messenger.L1MessageSent.
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    function sendToL1(bytes calldata _message) external returns (bytes32 hash) {
        hash = keccak256(_message);
        emit L1MessageSent(msg.sender, hash, _message);
        return hash;
    }
}
