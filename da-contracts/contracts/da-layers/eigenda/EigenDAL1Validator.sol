// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {OperatorDAInputTooSmall} from "../../DAContractsErrors.sol";

interface IEigenDABlobProofRegistry {
    function isVerified(bytes calldata inclusion_data) external view returns (bool, bytes32);
}

contract EigenDAL1Validator is IL1DAValidator {
    error InvalidValidatorOutputHash();
    error ProofNotVerified();

    IEigenDABlobProofRegistry public eigenDARegistry;

    constructor(address eigendaRegistryAddress) {
        eigenDARegistry = IEigenDABlobProofRegistry(eigendaRegistryAddress);
    }

    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber,
        bytes32 l2DAValidatorOutputHash,
        bytes calldata operatorDAInput,
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        if (operatorDAInput.length < 32) {
            revert OperatorDAInputTooSmall(operatorDAInput.length, 32);
        }
        bytes32 stateDiffHash = abi.decode(operatorDAInput[:32], (bytes32));

        (bool isVerified, bytes32 eigenDAHash) = eigenDARegistry.isVerified(operatorDAInput[32:]);

        if (!isVerified) revert ProofNotVerified();

        if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(stateDiffHash, eigenDAHash)))
            revert InvalidValidatorOutputHash();

        output.stateDiffHash = stateDiffHash;

        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
