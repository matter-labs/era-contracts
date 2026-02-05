// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title Interface for the L2 to L1 Messenger contract
interface IL2ToL1Messenger {
    /// @notice Sends an arbitrary length message to L1.
    /// @param _message The variable length message to be sent to L1.
    /// @return Returns the keccak256 hashed value of the message.
    function sendToL1(bytes calldata _message) external returns (bytes32);
}
