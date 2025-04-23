// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IL2DAValidator {
    function validatePubdata(
        // The rolling hash of the user L2->L1 logs.
        bytes32 _chainedLogsHash,
        // The root hash of the user L2->L1 logs.
        bytes32 _logsRootHash,
        // The chained hash of the L2->L1 messages
        bytes32 _chainedMessagesHash,
        // The chained hash of uncompressed bytecodes sent to L1
        bytes32 _chainedBytecodesHash,
        // Same operator input
        bytes calldata _totalL2ToL1PubdataAndStateDiffs
    ) external returns (bytes32 outputHash);
}
