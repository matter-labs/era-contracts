// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// This file is intended to be a *subset* of `da-contracts/contracts/BlobsL1DAValidatorZKsyncOS.sol:BlobsL1DAValidatorZKsyncOS`.
// We can not import the file directly due to issues during imports from folders outside of the project.


contract BlobsL1DAValidatorZKsyncOS {
    /// @notice The published blob versioned hashes.
    mapping(bytes32 versionedHash => uint256 blockOfPublishing) public publishedBlobs;

    /// @notice Publishes all the blobs provided with a transaction.
    function publishBlobs() external {
        uint256 versionedHashIndex = 0;
        // iterate through all the published blobs in the tx (until versionedHash for index equals to 0)
        while (true) {
            bytes32 versionedHash = _getBlobVersionedHash(versionedHashIndex);
            if (versionedHash == bytes32(0)) {
                break;
            }
            publishedBlobs[versionedHash] = block.number;
            ++versionedHashIndex;
        }
    }

    function _getBlobVersionedHash(uint256 _index) internal view virtual returns (bytes32 versionedHash) {
        assembly {
            versionedHash := blobhash(_index)
        }
    }
}