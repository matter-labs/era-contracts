// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {OperatorDAInputTooSmall} from "../../DAContractsErrors.sol";

interface IEigenDABlobProofRegistry {
    function isVerified(bytes calldata inclusion_data) external view returns (bool, bytes32);
}

contract EigenDAL1DAValidator is IL1DAValidator {
    error InvalidValidatorOutputHash();
    error ProofNotVerified();

    IEigenDABlobProofRegistry public eigenDARegistry;

    constructor(address eigendaRegistryAddress) {
        eigenDARegistry = IEigenDABlobProofRegistry(eigendaRegistryAddress);
    }

    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber,
        bytes32 l2DAValidatorOutputHash, // keccak(stateDiffHash, eigenDAHash) Calculated on EigenDAL2DAValidator and passed through L2->L1 Logs
        bytes calldata operatorDAInput, // stateDiffHash + inclusion_data (inclusion data == abi encoded blobInfo, aka EigenDACert)
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        if (operatorDAInput.length < 32) {
            revert OperatorDAInputTooSmall(operatorDAInput.length, 32);
        }
        bytes32 stateDiffHash = bytes32(operatorDAInput[:32]);

        // Check that the proof for the given inclusion data was verified in the EigenDA registry contract
        (bool isVerified, bytes32 eigenDAHash) = eigenDARegistry.isVerified(operatorDAInput[32:]);

        if (!isVerified) revert ProofNotVerified();

        // Check that the eigenDAHash from the EigenDARegistry (originally calculted on Risc0 guest) is correct
        if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(stateDiffHash, eigenDAHash)))
            revert InvalidValidatorOutputHash();

        output.stateDiffHash = stateDiffHash;

        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
