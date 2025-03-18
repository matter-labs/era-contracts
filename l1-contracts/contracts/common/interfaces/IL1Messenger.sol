// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface of the L1 Messenger contract, responsible for sending messages to L1.
 */
interface IL1Messenger {
    function sendToL1(bytes calldata _message) external returns (bytes32);
}
