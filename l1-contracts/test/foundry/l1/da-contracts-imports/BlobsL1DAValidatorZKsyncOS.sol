// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// This provides an interface for `da-contracts/contracts/BlobsL1DAValidatorZKsyncOS.sol:BlobsL1DAValidatorZKsyncOS`.
// We can not import the file directly due to issues during imports from folders outside of the project.
interface BlobsL1DAValidatorZKsyncOS {
    /// @notice The published blob versioned hashes.
    function publishedBlobs(bytes32 _versionedHash) external view returns (uint256 blockOfPublishing);

    /// @notice Publishes all the blobs provided with a transaction.
    function publishBlobs() external;
}
