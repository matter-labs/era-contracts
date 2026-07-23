// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "./IL1DAValidator.sol";
import {InvalidL2DAOutputHash} from "./DAContractsErrors.sol";

/// @title CalldataL1DAValidatorZKsyncOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The calldata-based L1 DA validator for ZKsync OS chains — the calldata counterpart of
/// {BlobsL1DAValidatorZKsyncOS}. The operator publishes the batch's DA payload directly as L1 calldata and
/// this validator forces it to match the proven `daCommitment` by checking
/// `keccak256(operatorDAInput) == daCommitment`.
/// @dev It is content-blind: whether the calldata carries the full pubdata (Rollup mode) or only the
/// mandatory L2->L1 log region (the log records, which include user-message hashes and the interop-commitment
/// (IMT) leaves; message preimages and state diffs left to the operator) in Validium mode — is decided by the
/// STF when it builds the commitment, not here. Atomic-interop chains use Validium mode to keep their interop
/// (IMT) data reconstructible from L1. Publishing as calldata keeps the data permanently available, unlike
/// EIP-4844 blobs, which expire after a few weeks.
/// @dev Like {BlobsL1DAValidatorZKsyncOS}, the returned output is unused on ZKsync OS (state diffs and blob
/// content are bound by the batch proof), so it returns a zero state-diff hash and empty blob arrays.
contract CalldataL1DAValidatorZKsyncOS is IL1DAValidator {
    /// @inheritdoc IL1DAValidator
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 // _maxBlobsSupported
    ) external pure returns (L1DAValidatorOutput memory output) {
        // Force the operator to publish, as calldata, exactly the payload committed by the batch: the bytes
        // are now available on L1 for anyone to read (e.g. to reconstruct the interop IMT).
        if (keccak256(_operatorDAInput) != _l2DAValidatorOutputHash) {
            revert InvalidL2DAOutputHash(_l2DAValidatorOutputHash);
        }

        // The output is ignored on ZKsync OS (state diffs and blob content are bound by the batch proof);
        // return empty arrays, mirroring `BlobsL1DAValidatorZKsyncOS`.
        output.stateDiffHash = bytes32(0);
        output.blobsLinearHashes = new bytes32[](0);
        output.blobsOpeningCommitments = new bytes32[](0);
    }
}
