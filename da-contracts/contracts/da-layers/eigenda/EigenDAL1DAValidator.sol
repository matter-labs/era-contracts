// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {OperatorDAInputTooSmall} from "../../DAContractsErrors.sol";

interface IRiscZeroVerifier {
    function verify(bytes calldata seal, bytes32 imageId, bytes32 journalDigest) external view;
}

struct Journal {
    bytes32 eigenDAHash; // The hash of the EigenDA data calculated by the Risc0 guest
    bytes env_commitment; // The abi-encoded steel commitment
    bytes proof; // The KZG Proof for proof of equivalence
}

struct EigenDAInclusionData {
    bytes seal;
    bytes32 imageId;
    bytes journal;
}

contract EigenDAL1DAValidator is IL1DAValidator {
    error InvalidValidatorOutputHash();
    error ProofNotVerified();

    IRiscZeroVerifier public risc0Verifier;

    constructor(address risc0VerifierAddress) {
        risc0Verifier = IRiscZeroVerifier(risc0VerifierAddress);
    }

    /// Verifies a zk proof of an eth-call to https://github.com/Layr-Labs/eigenda/blob/805492f803416c258b8aa7dff90c7d5cc4b750bd/contracts/src/periphery/cert/interfaces/IEigenDACertVerifierBase.sol#L8
    /// It is only compatible with EigenDACertV3 https://github.com/Layr-Labs/eigenda/blob/805492f803416c258b8aa7dff90c7d5cc4b750bd/contracts/src/periphery/cert/EigenDACertTypes.sol#L11
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber,
        bytes32 l2DAValidatorOutputHash, // keccak(stateDiffHash, eigenDAHash) Calculated on EigenDAL2DAValidator and passed through L2->L1 Logs
        bytes calldata operatorDAInput, // stateDiffHash + inclusion_data (abi encoded EigenDAInclusionData)
        uint256 maxBlobsSupported
    ) external override returns (L1DAValidatorOutput memory output) {
        if (operatorDAInput.length < 32) {
            revert OperatorDAInputTooSmall(operatorDAInput.length, 32);
        }
        output.stateDiffHash = bytes32(operatorDAInput[:32]);

        // Decode the inclusion data from the operatorDAInput
        EigenDAInclusionData memory inclusionData = abi.decode(operatorDAInput[32:], (EigenDAInclusionData));

        // Decode the journal (public outputs)
        Journal memory journal = abi.decode(inclusionData.journal, (Journal));

        // Verify the risczero proof
        risc0Verifier.verify(inclusionData.seal, inclusionData.imageId, sha256(inclusionData.journal));

        // Check that the eigenDAHash from the Inclusion Data (originally calculated on Risc0 guest) is correct
        if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(output.stateDiffHash, journal.eigenDAHash)))
            revert InvalidValidatorOutputHash();

        output.blobsLinearHashes = new bytes32[](maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](maxBlobsSupported);
    }
}
