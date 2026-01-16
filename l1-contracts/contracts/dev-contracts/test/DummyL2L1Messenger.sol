// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

contract DummyL2L1Messenger {
    function sendToL1(bytes calldata _message) external returns (bytes32 hash) {
        emit L1MessageSent(msg.sender, hash, _message);
    }
}
