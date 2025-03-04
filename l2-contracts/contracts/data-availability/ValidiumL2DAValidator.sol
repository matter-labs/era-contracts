// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2DAValidator} from "../interfaces/IL2DAValidator.sol";

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
        // Since we do not need to publish anything to L1, we can just return 0.
        // Note, that Rollup validator sends the hash of uncompressed state diffs, since the
        // correctness of the publish pubdata depends on it. However Validium doesn't sent anything,
        // so we don't need to publish even that.
        outputHash = bytes32(0);
    }
}
