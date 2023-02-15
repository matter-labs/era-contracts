// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IL1Messenger {
    // Possibly in the future we will be able to track the messages sent to L1 with
    // some hooks in the VM. For now, it is much easier to track them with L2 events.
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    function sendToL1(bytes memory _message) external returns (bytes32);
}
