// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2DAValidator} from "../interfaces/IL2DAValidator.sol";
import {StateDiffL2DAValidator} from "./StateDiffL2DAValidator.sol";

import {EfficientCall} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/EfficientCall.sol";
import {ReconstructionMismatch, PubdataField} from "./DAErrors.sol";

/// BitcoinDA validator. It will publish inclusion data that would allow to verify the inclusion.
contract RollupL2DAValidator is IL2DAValidator, StateDiffL2DAValidator {
    function validatePubdata(
        // The rolling hash of the user L2->L1 logs.
        bytes32,
        // The root hash of the user L2->L1 logs.
        bytes32,
        // The chained hash of the L2->L1 messages
        bytes32 _chainedMessagesHash,
        // The chained hash of uncompressed bytecodes sent to L1
        bytes32 _chainedBytecodesHash,
        // Operator data, that is related to the DA itself
        bytes calldata _totalL2ToL1PubdataAndStateDiffs
    ) external returns (bytes32 outputHash) {
        (
            bytes32 uncompressedStateDiffHash,
            bytes calldata _totalPubdata,
            bytes calldata leftover
        ) = _produceStateDiffPubdata(_chainedMessagesHash, _chainedBytecodesHash, _totalL2ToL1PubdataAndStateDiffs);

        /// Check for calldata strict format
        if (leftover.length != 0) {
            revert ReconstructionMismatch(PubdataField.ExtraData, bytes32(0), bytes32(leftover.length));
        }

        // The preimage under the hash `outputHash` is expected to be in the following format:
        // - First 32 bytes are the hash of the uncompressed state diff.
        // - Then, there is a 32-byte hash of the DA.

        outputHash = keccak256(abi.encodePacked(uncompressedStateDiffHash, EfficientCall.keccak(_totalPubdata)));
    }
}
