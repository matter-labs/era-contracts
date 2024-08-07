// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {IL1DAValidator, L1DAValidatorOutput} from "./IL1DAValidator.sol";

contract ValidiumL1DAValidator is IL1DAValidator {
    function checkDA(
        uint256, // _chainId
        bytes32, // _l2DAValidatorOutputHash
        bytes calldata _operatorDAInput,
        uint256 // maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        // For Validiums, we expect the operator to just provide the data for us.
        // We don't need to do any checks with regard to the l2DAValidatorOutputHash.
        require(_operatorDAInput.length == 32);

        bytes32 stateDiffHash = abi.decode(_operatorDAInput, (bytes32));

        // The rest of the fields that relate to blobs are empty.
        output.stateDiffHash = stateDiffHash;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return (interfaceId == this.supportsInterface.selector) || (interfaceId == type(IL1DAValidator).interfaceId);
    }
}
