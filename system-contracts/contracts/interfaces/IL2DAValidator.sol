// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IL2DAValidator {
    function validatePubdata(
        // The rolling hash of the user L2->L1 logs.
        bytes32 _chainedLogsHash,
        // The root hash of the user L2->L1 logs.
        bytes32 _logsRootHash,
        // The chained hash of the L2->L1 messages
        bytes32 _chainedMessagesHash,
        // The chained hash of uncompressed bytecodes sent to L1
        bytes32 _chainedBytescodesHash,
        // Same operator input
        bytes calldata _operatorInput
    ) external returns (bytes32 outputHash);
}
