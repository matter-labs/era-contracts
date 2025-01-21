// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// This file is intended to be a *subset* of `da-contracts/contracts/CalldataDA.sol`.
// We can not import the file directly due to issues during imports from folders outside of the project.

/// @dev Total number of bytes in a blob. Blob = 4096 field elements * 31 bytes per field element
/// @dev EIP-4844 defines it as 131_072 but we use 4096 * 31 within our circuits to always fit within a field element
/// @dev Our circuits will prove that a EIP-4844 blob and our internal blob are the same.
uint256 constant BLOB_SIZE_BYTES = 126_976;

/// @dev The state diff hash, hash of pubdata + the number of blobs.
uint256 constant BLOB_DATA_OFFSET = 65;

/// @dev The size of the commitment for a single blob.
uint256 constant BLOB_COMMITMENT_SIZE = 32;
