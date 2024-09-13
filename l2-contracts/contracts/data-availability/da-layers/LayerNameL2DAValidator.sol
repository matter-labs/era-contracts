// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2DAValidator} from "../../interfaces/IL2DAValidator.sol";

/// Rollup DA validator. It will publish data that would allow to use either calldata or blobs.
contract ValidiumL2DAValidator is IL2DAValidator {
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
        bytes calldata
    ) external returns (bytes32 outputHash) {
        // Look into the RollupL2DAValidator.sol for a reference of how to get the pubdata, so you are able to commit to it
        // here, and then reuse this commitment on in L1DAValidator.
        outputHash = bytes32(0);
    }
}
