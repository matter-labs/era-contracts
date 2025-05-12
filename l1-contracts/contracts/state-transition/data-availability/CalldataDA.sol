// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {OperatorDAInputTooSmall, InvalidNumberOfBlobs, InvalidL2DAOutputHash, OnlyOneBlobWithCalldataAllowed, PubdataInputTooSmall, PubdataLengthTooBig, InvalidPubdataHash} from "../L1StateTransitionErrors.sol";

/// @dev Total number of bytes in a blob. Blob = 4096 field elements * 31 bytes per field element
/// @dev EIP-4844 defines it as 131_072 but we use 4096 * 31 within our circuits to always fit within a field element
/// @dev Our circuits will prove that a EIP-4844 blob and our internal blob are the same.
uint256 constant BLOB_SIZE_BYTES = 126_976;

/// @dev The state diff hash, hash of pubdata + the number of blobs.
uint256 constant BLOB_DATA_OFFSET = 65;

/// @dev The size of the commitment for a single blob.
uint256 constant BLOB_COMMITMENT_SIZE = 32;

/// @notice Contract that contains the functionality for process the calldata DA.
/// @dev The expected l2DAValidator that should be used with it `RollupL2DAValidator`.
abstract contract CalldataDA {
    /// @notice Parses the input that the L2 DA validator has provided to the contract.
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
        if (_operatorDAInput.length < BLOB_DATA_OFFSET) {
            revert OperatorDAInputTooSmall(_operatorDAInput.length, BLOB_DATA_OFFSET);
        }

        stateDiffHash = bytes32(_operatorDAInput[:32]);
        fullPubdataHash = bytes32(_operatorDAInput[32:64]);
        blobsProvided = uint256(uint8(_operatorDAInput[64]));

        if (blobsProvided > _maxBlobsSupported) {
            revert InvalidNumberOfBlobs(blobsProvided, _maxBlobsSupported);
        }

        // Note that the API of the contract requires that the returned blobs linear hashes have length of
        // the `_maxBlobsSupported`
        blobsLinearHashes = new bytes32[](_maxBlobsSupported);

        if (_operatorDAInput.length < BLOB_DATA_OFFSET + 32 * blobsProvided) {
            revert OperatorDAInputTooSmall(_operatorDAInput.length, BLOB_DATA_OFFSET + 32 * blobsProvided);
        }

        _cloneCalldata(blobsLinearHashes, _operatorDAInput[BLOB_DATA_OFFSET:], blobsProvided);

        uint256 ptr = BLOB_DATA_OFFSET + 32 * blobsProvided;

        // Now, we need to double check that the provided input was indeed returned by the L2 DA validator.
        if (keccak256(_operatorDAInput[:ptr]) != _l2DAValidatorOutputHash) {
            revert InvalidL2DAOutputHash(_l2DAValidatorOutputHash);
        }

        // The rest of the output was provided specifically by the operator
        l1DaInput = _operatorDAInput[ptr:];
    }

    /// @notice Verify that the calldata DA was correctly provided.
    /// @param _blobsProvided The number of blobs provided.
    /// @param _fullPubdataHash Hash of the pubdata preimage.
    /// @param _maxBlobsSupported Maximum number of blobs supported.
    /// @param _pubdataInput Full pubdata + an additional 32 bytes containing the blob commitment for the pubdata.
    /// @dev We supply the blob commitment as part of the pubdata because even with calldata the prover will check these values.
    function _processCalldataDA(
        uint256 _blobsProvided,
        bytes32 _fullPubdataHash,
        uint256 _maxBlobsSupported,
        bytes calldata _pubdataInput
    ) internal pure virtual returns (bytes32[] memory blobCommitments, bytes calldata _pubdata) {
        if (_blobsProvided != 1) {
            revert OnlyOneBlobWithCalldataAllowed();
        }
        if (_pubdataInput.length < BLOB_COMMITMENT_SIZE) {
            revert PubdataInputTooSmall(_pubdataInput.length, BLOB_COMMITMENT_SIZE);
        }

        // We typically do not know whether we'll use calldata or blobs at the time when
        // we start proving the batch. That's why the blob commitment for a single blob is still present in the case of calldata.

        blobCommitments = new bytes32[](_maxBlobsSupported);

        _pubdata = _pubdataInput[:_pubdataInput.length - BLOB_COMMITMENT_SIZE];

        if (_pubdata.length > BLOB_SIZE_BYTES) {
            revert PubdataLengthTooBig(_pubdata.length, BLOB_SIZE_BYTES);
        }
        if (_fullPubdataHash != keccak256(_pubdata)) {
            revert InvalidPubdataHash(_fullPubdataHash, keccak256(_pubdata));
        }
        blobCommitments[0] = bytes32(_pubdataInput[_pubdataInput.length - BLOB_COMMITMENT_SIZE:_pubdataInput.length]);
    }

    /// @notice Method that clones a slice of calldata into a bytes32[] memory array.
    /// @param _dst The destination array.
    /// @param _input The input calldata.
    /// @param _len The length of the slice in 32-byte words to clone.
    function _cloneCalldata(bytes32[] memory _dst, bytes calldata _input, uint256 _len) internal pure {
        assembly {
            // The pointer to the allocated memory above. We skip 32 bytes to avoid overwriting the length.
            let dstPtr := add(_dst, 0x20)
            let inputPtr := _input.offset
            calldatacopy(dstPtr, inputPtr, mul(_len, 32))
        }
    }
}
