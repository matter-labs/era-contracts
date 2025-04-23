// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL2DAValidator} from "../interfaces/IL2DAValidator.sol";
import {StateDiffL2DAValidator} from "./StateDiffL2DAValidator.sol";

/// Avail L2 DA validator. It will create a commitment to the pubdata that can later be verified during settlement.
contract AvailL2DAValidator is IL2DAValidator, StateDiffL2DAValidator {
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
        (bytes32 stateDiffHash, bytes calldata _totalPubdata, ) = _produceStateDiffPubdata(
            _chainedMessagesHash,
            _chainedBytecodesHash,
            _totalL2ToL1PubdataAndStateDiffs
        );

        bytes32 fullPubdataHash = keccak256(_totalPubdata);
        outputHash = keccak256(abi.encodePacked(stateDiffHash, fullPubdataHash));
    }
}
