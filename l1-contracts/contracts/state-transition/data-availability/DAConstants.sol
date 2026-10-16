// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @dev BLS Modulus value defined in EIP-4844 and the magic value returned from a successful call to the
/// point evaluation precompile
uint256 constant BLS_MODULUS = 52435875175126190479447740508185965837690552500527637822603658699938581184513;

/// @dev Packed pubdata commitments.
/// @dev Format: list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)) = 144 bytes
uint256 constant PUBDATA_COMMITMENT_SIZE = 144;

/// @dev Offset in pubdata commitment of blobs for claimed value
uint256 constant PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET = 16;

/// @dev Offset in pubdata commitment of blobs for kzg commitment
uint256 constant PUBDATA_COMMITMENT_COMMITMENT_OFFSET = 48;

/// @dev For each blob we expect that the commitment is provided as well as the marker whether a blob with such commitment has been published before.
uint256 constant BLOB_DA_INPUT_SIZE = PUBDATA_COMMITMENT_SIZE + 32;

/// @dev Address of the point evaluation precompile used for EIP-4844 blob verification.
address constant POINT_EVALUATION_PRECOMPILE_ADDR = address(0x0A);

/// @dev The number of blocks within each we allow blob to be used for DA.
/// On Ethereum blobs expire within 4096 epochs, i.e. 4096 * 32 blocks. We reserve
/// half of the time in order to ensure reader's ability to read the blob's content.
uint256 constant BLOB_EXPIRATION_BLOCKS = (4096 * 32) / 2;

/// @dev The size in bytes of the versioned hash for a single blob.
uint256 constant BLOB_VERSIONED_HASH_SIZE = 32;
