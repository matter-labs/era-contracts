// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @dev Total number of bytes in a blob. Blob = 4096 field elements * 31 bytes per field element
/// @dev EIP-4844 defines it as 131_072 but we use 4096 * 31 within our circuits to always fit within a field element
/// @dev Our circuits will prove that a EIP-4844 blob and our internal blob are the same.
uint256 constant BLOB_SIZE_BYTES = 126_976;

/// @dev Enum used to determine the source of pubdata. At first we will support calldata and blobs but this can be extended.
enum PubdataSource {
    Calldata,
    Blob
}

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

/// @dev The address of the special smart contract that can send arbitrary length message as an L2 log
address constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR = address(0x8008);
