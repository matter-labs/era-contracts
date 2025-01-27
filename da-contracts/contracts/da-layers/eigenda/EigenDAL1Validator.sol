// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
contract EigenDAL1Validator is IL1DAValidator {
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32, // _l2DAValidatorOutputHash
        bytes calldata _operatorDAInput,
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        // TODO: Implement real validation logic for M1.
        output.stateDiffHash = bytes32(0);
        output.blobsLinearHashes = new bytes32[](0);
        output.blobsOpeningCommitments = new bytes32[](0);
    }
}
