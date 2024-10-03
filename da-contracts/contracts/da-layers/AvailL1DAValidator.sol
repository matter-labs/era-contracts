// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {IL1DAValidator, L1DAValidatorOutput} from "../IL1DAValidator.sol";
import {IAvailBridge} from "../IAvailBridge.sol";
import {AvailAttestationLib} from "../lib/AvailAttestationLib.sol";

contract AvailL1DAValidator is IL1DAValidator, AvailAttestationLib {
    constructor(IAvailBridge _availBridge) AvailAttestationLib(_availBridge) {}

    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32, // _l2DAValidatorOutputHash
        bytes calldata operatorDAInput,
        uint256 maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {
        IAvailBridge.MerkleProofInput memory input = abi.decode(operatorDAInput, (IAvailBridge.MerkleProofInput));
        _attest(input);

        // The rest of the fields that relate to blobs are empty.
        output.stateDiffHash = input.leaf;
        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
