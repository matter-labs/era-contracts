// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {BLOB_SIZE_BYTES} from "./DAUtils.sol";

uint256 constant BLOBS_SUPPORTED = 6;

/// @notice Contract that contains the functionality for processing the calldata DA.
/// @dev The expected l2DAValidator that should be used with it `RollupL2DAValidator`.
abstract contract CalldataDA {
    /// @notice Parses the input that the l2 DA validator has provided to the contract.
    /// @param _l2DAValidatorOutputHash The hash of the output of the L2 DA validator.
    /// @param _maxBlobsSupported The maximal number of blobs supported by the chain.
    /// @param _operatorDAInput The DA input by the operator provided on L1.
    function _processL2RollupDAValidatorOutputHash(
        bytes32 _l2DAValidatorOutputHash,
        uint256 _maxBlobsSupported,
        bytes calldata _operatorDAInput
    )
        internal
        pure
        returns (
            bytes32 stateDiffHash,
            bytes32 fullPubdataHash,
            bytes32[] memory blobsLinearHashes,
            uint256 blobsProvided,
            bytes calldata l1DaInput
        )
    {
        // The preimage under the hash `_l2DAValidatorOutputHash` is expected to be in the following format:
        // - First 32 bytes are the hash of the uncompressed state diff.
        // - Then, there is a 32-byte hash of the full pubdata.
        // - Then, there is the 1-byte number of blobs published.
        // - Then, there are linear hashes of the published blobs, 32 bytes each.

        // Check that it accommodates enough pubdata for the state diff hash, hash of pubdata + the number of blobs.
        require(_operatorDAInput.length >= 32 + 32 + 1, "too small");

        stateDiffHash = bytes32(_operatorDAInput[:32]);
        fullPubdataHash = bytes32(_operatorDAInput[32:64]);
        blobsProvided = uint256(uint8(_operatorDAInput[64]));

        require(blobsProvided <= _maxBlobsSupported, "invalid number of blobs");

        // Note that the API of the contract requires that the returned blobs linear hashes have length of
        // the `_maxBlobsSupported`
        blobsLinearHashes = new bytes32[](_maxBlobsSupported);

        require(_operatorDAInput.length >= 65 + 32 * blobsProvided, "invalid blobs hashes");

        uint256 ptr = 65;

        for (uint256 i = 0; i < blobsProvided; ++i) {
            // Take the 32 bytes of the blob linear hash
            blobsLinearHashes[i] = bytes32(_operatorDAInput[ptr:ptr + 32]);
            ptr += 32;
        }

        // Now, we need to double check that the provided input was indeed returned by the L2 DA validator.
        require(keccak256(_operatorDAInput[:ptr]) == _l2DAValidatorOutputHash, "invalid l2 DA output hash");

        // The rest of the output was provided specifically by the operator
        l1DaInput = _operatorDAInput[ptr:];
    }

    /// @notice Verify that the calldata DA was correctly provided.
    /// todo: better doc comments
    function _processCalldataDA(
        uint256 _blobsProvided,
        bytes32 _fullPubdataHash,
        uint256 _maxBlobsSupported,
        bytes calldata _pubdataInput
    ) internal pure returns (bytes32[] memory blobCommitments, bytes calldata _pubdata) {
        // We typically do not know whether we'll use calldata or blobs at the time when
        // we start proving the batch. That's why the blob commitment for a single blob is still present in the case of calldata.

        blobCommitments = new bytes32[](_maxBlobsSupported);

        require(_blobsProvided == 1, "one blob with calldata");

        _pubdata = _pubdataInput[:_pubdataInput.length - 32];

        // FIXME: allow larger lengths for SyncLayer-based chains.
        require(_pubdata.length <= BLOB_SIZE_BYTES, "cz");
        require(_fullPubdataHash == keccak256(_pubdata), "wp");
        blobCommitments[0] = bytes32(_pubdataInput[_pubdataInput.length - 32:_pubdataInput.length]);
    }
}
