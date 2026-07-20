// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "./IL1DAValidator.sol";
import {InvalidL2DAOutputHash} from "./DAContractsErrors.sol";

/// @title CalldataL1DAValidatorZKsyncOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The calldata-based L1 DA validator for ZKsync OS chains — the calldata counterpart of
/// {BlobsL1DAValidatorZKsyncOS}: the operator publishes the batch's DA payload directly as L1 calldata and
/// this validator checks `keccak256(operatorDAInput) == daCommitment`.
/// @dev Content-blind: whether the calldata carries the full pubdata or only a subset (e.g. the L2->L1
/// region under the `L2_TO_L1_ONLY` scheme, which atomic-interop chains use to keep their IMT data
/// reconstructible from L1) is decided by the STF when it builds the commitment, not here. Calldata stays
/// permanently available, unlike EIP-4844 blobs.
/// @dev The returned output is unused on ZKsync OS (state diffs and blob content are bound by the batch
/// proof), so it returns a zero state-diff hash and empty blob arrays.
contract CalldataL1DAValidatorZKsyncOS is IL1DAValidator {
    /// @inheritdoc IL1DAValidator
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 // _maxBlobsSupported
    ) external pure returns (L1DAValidatorOutput memory output) {
        if (keccak256(_operatorDAInput) != _l2DAValidatorOutputHash) {
            revert InvalidL2DAOutputHash(_l2DAValidatorOutputHash);
        }

        output.stateDiffHash = bytes32(0);
        output.blobsLinearHashes = new bytes32[](0);
        output.blobsOpeningCommitments = new bytes32[](0);
    }
}
