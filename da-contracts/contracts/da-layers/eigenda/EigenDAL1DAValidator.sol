// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {OperatorDAInputTooSmall} from "../../DAContractsErrors.sol";

interface IRiscZeroVerifier {
    function verify(bytes calldata seal, bytes32 imageId, bytes32 journalDigest) external view;
}

struct EigenDAInclusionData {
    bytes seal;
    bytes32 imageId;
    bytes32 journalDigest;
    bytes32 eigenDAHash;
}

contract EigenDAL1DAValidator is IL1DAValidator {
    error InvalidValidatorOutputHash();
    error ProofNotVerified();

    IRiscZeroVerifier public risc0Verifier;

    constructor(address risc0VerifierAddress) {
        risc0Verifier = IRiscZeroVerifier(risc0VerifierAddress);
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

        // Decode the inclusion data from the operatorDAInput
        EigenDAInclusionData memory inclusionData = abi.decode(operatorDAInput[32:], (EigenDAInclusionData));

        // Verify the risczero proof
        risc0Verifier.verify(inclusionData.seal, inclusionData.imageId, inclusionData.journalDigest);

        // Check that the eigenDAHash from the Inclusion Data (originally calculated on Risc0 guest) is correct
        if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(stateDiffHash, inclusionData.eigenDAHash)))
            revert InvalidValidatorOutputHash();

        output.stateDiffHash = stateDiffHash;

        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
