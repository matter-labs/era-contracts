// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2DAValidator} from "../../interfaces/IL2DAValidator.sol";

/// Rollup DA validator. It will publish data that would allow to use either calldata or blobs.
contract AvailL2DAValidator is IL2DAValidator {
    function validatePubdata(
        // The rolling hash of the user L2->L1 logs.
        bytes32,
        // The root hash of the user L2->L1 logs.
        bytes32,
        // The chained hash of the L2->L1 messages
        bytes32,
        // The chained hash of uncompressed bytecodes sent to L1
        bytes32,
        // Operator data, that is related to the DA itself
        bytes calldata totalL2ToL1PubdataAndStateDiffs
    ) external returns (bytes32 outputHash) {
        outputHash = keccak256(totalL2ToL1PubdataAndStateDiffs);
    }
}
