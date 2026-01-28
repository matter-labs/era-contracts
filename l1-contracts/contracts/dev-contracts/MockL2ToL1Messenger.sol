// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL2ToL1Messenger
/// @notice A minimal mock for testing that returns keccak256 hash of the message
contract MockL2ToL1Messenger {
    /// @notice Sends a message to L1
    /// @param _message The message to send
    /// @return hash The keccak256 hash of the message
    function sendToL1(bytes calldata _message) external returns (bytes32 hash) {
        return keccak256(_message);
    }
}
