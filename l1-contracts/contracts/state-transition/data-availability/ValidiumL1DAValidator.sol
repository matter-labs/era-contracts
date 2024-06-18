// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import { IL1DAValidator, L1DAValidatorOutput } from "../chain-interfaces/IL1DAValidator.sol";

// TODO: maybe move it here
import { PubdataSource, PUBDATA_COMMITMENT_SIZE } from "../chain-interfaces/IExecutor.sol";

contract ValidiumL1DAValidator is IL1DAValidator {
    function checkDA(
        bytes32 l2DAValidatorOutputHash,
        bytes memory operatorDAInput,
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        // For Validiums, we expect the operator to just provide the data for us.
        // We don't need to do any checks with regard to the l2DAValidatorOutputHash.
        require(operatorDAInput.length == 32);

        bytes32 stateDiffHash = abi.decode(operatorDAInput, (bytes32));

        // The rest of the fields that relate to blobs are empty.
        output.stateDiffHash = stateDiffHash;
    }
}
