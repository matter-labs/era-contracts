// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2DAValidator {
    function validatePubdata(
        // The rolling hash of the user L2->L1 logs.
        bytes32 chainedLogsHash,
        // The root hash of the user L2->L1 logs.
        bytes32 logsRootHash,
        // The chained hash of the L2->L1 messages
        bytes32 chainedMessagesHash,
        // The chained hash of uncompressed bytecodes sent to L1
        bytes32 chainedBytescodesHash,
        // Same operator input
        bytes calldata totalL2ToL1PubdataAndStateDiffs
    ) external returns (bytes32 outputHash);
}
