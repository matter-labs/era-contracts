// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

struct L1DAValidatorOutput {
    /// @dev The hash of the uncompressed state diff.
    bytes32 stateDiffHash;
    /// @dev The hashes of the blobs on L1. The array is dynamic to account for forward compatibility.
    /// The length of it must be equal to `maxBlobsSupported`.
    bytes32[] blobsLinearHashes;
    /// @dev The commitments to the blobs on L1. The array is dynamic to account for forward compatibility.
    /// Its length must be equal to the length of blobsLinearHashes.
    /// @dev If the system supports more blobs than returned, the rest of the array should be filled with zeros.
    bytes32[] blobsOpeningCommitments;
}

// TODO: require EIP165 support as this will allow changes for future compatibility.
interface IL1DAValidator {
    /// @notice The function that checks the data availability for the given batch input.
    /// @param chainId The chain id of the chain that is being committed.
    /// @param l2DAValidatorOutputHash The hash of that was returned by the l2DAValidator.
    /// @param operatorDAInput The DA input by the operator provided on L1.
    /// @param maxBlobsSupported The maximal number of blobs supported by the chain.
    /// We provide this value for future compatibility.
    /// This is needed because the corresponding `blobsLinearHashes`/`blobsOpeningCommitments`
    /// in the `L1DAValidatorOutput` struct will have to have this length as it is required
    /// to be static by the circuits.
    function checkDA(
        uint256 chainId,
        bytes32 l2DAValidatorOutputHash,
        bytes calldata operatorDAInput,
        uint256 maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output);
}
