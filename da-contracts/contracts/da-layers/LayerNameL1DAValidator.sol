// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {IL1DAValidator, L1DAValidatorOutput} from "../IL1DAValidator.sol";

contract LayerNameL1DAValidator is IL1DAValidator {
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32, // _l2DAValidatorOutputHash
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {
        // - use the _l2DAValidatorOutputHash to verify that the pubdata is the data which inclusion is being verified here
        // - encode any data you need into the _operatorDAInput, feel free to define any structs you need and use `abi.decode` with them
        // - set the output.stateDiffHash (must be a part of _operatorDAInput)

        // just replace this with `output.stateDiffHash = YourStruct.stateDiffHash;`
        output.stateDiffHash = bytes32(0);
        output.blobsLinearHashes = new bytes32[](_maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](_maxBlobsSupported);
    }
}
