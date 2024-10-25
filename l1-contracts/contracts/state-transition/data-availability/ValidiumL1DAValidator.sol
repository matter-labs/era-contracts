// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../chain-interfaces/IL1DAValidator.sol";
import {ValL1DAWrongInputLength} from "../L1StateTransitionErrors.sol";

contract ValidiumL1DAValidator is IL1DAValidator {
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32, // _l2DAValidatorOutputHash
        bytes calldata _operatorDAInput,
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        // For Validiums, we expect the operator to just provide the data for us.
        // We don't need to do any checks with regard to the l2DAValidatorOutputHash.
        if (_operatorDAInput.length != 32) {
            revert ValL1DAWrongInputLength(_operatorDAInput.length, 32);
        }
        bytes32 stateDiffHash = abi.decode(_operatorDAInput, (bytes32));

        // The rest of the fields that relate to blobs are empty.
        output.stateDiffHash = stateDiffHash;

        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
