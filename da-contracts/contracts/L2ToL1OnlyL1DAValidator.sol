// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "./IL1DAValidator.sol";
import {InvalidL2DAOutputHash} from "./DAContractsErrors.sol";

/// @title L2ToL1OnlyL1DAValidator
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1 DA validator for the `L2DACommitmentScheme.L2_TO_L1_ONLY` scheme on ZKsync OS.
/// @dev A chain on this scheme force-publishes ONLY its L2->L1 region (the L2->L1 logs + their message
/// preimages) on L1 as calldata, while its state diffs are not published. It targets chains that must keep
/// their L2->L1 data — e.g. the interop Indexed-Merkle-Tree data — permanently reconstructible from L1 by any
/// participant. Publishing as calldata (rather than blobs) makes the data permanently available: blobs expire
/// after a few weeks, but a non-inclusion proof for an interop route may be exercised long after that.
/// So for blobs option of publishing L2->L1 data chains/external parties ultimately must have an off-chain
/// service that is reading blobs while they are still available. For calldata option it's not essential,
/// data lives on-chain perpetually.
///
/// @dev The operator hands the exact L2->L1 region as `_operatorDAInput`; this validator forces its
/// publication by checking it hashes to the proven `daCommitment` (`_l2DAValidatorOutputHash`). The STF is
/// responsible for setting `daCommitment = keccak256(region)` and for binding that the region is the correct
/// one — this validator only guarantees the committed bytes are available on L1.
contract L2ToL1OnlyL1DAValidator is IL1DAValidator {
    /// @inheritdoc IL1DAValidator
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 // _maxBlobsSupported
    ) external pure returns (L1DAValidatorOutput memory output) {
        // Force the operator to publish the exact L2->L1 region committed by the batch: the bytes are now
        // available on L1 (as calldata) for any interop participant to reconstruct the IMT.
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
