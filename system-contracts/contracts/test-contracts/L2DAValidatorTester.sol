// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {L2DAValidator} from "../libraries/L2DAValidator.sol";
import {L2DACommitmentScheme} from "../Constants.sol";

contract L2DAValidatorTester {
    function validatePubdata(
        L2DACommitmentScheme _l2DACommitmentScheme,
        bytes32 _chainedMessagesHash,
        bytes32 _chainedBytecodesHash,
        bytes calldata _operatorData
    ) external view returns (bytes32 outputHash) {
        outputHash = L2DAValidator.makeDACommitment(
            _l2DACommitmentScheme,
            _chainedMessagesHash,
            _chainedBytecodesHash,
            _operatorData
        );
    }
}
