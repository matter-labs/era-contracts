// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPubdataChunkPublisher} from "./interfaces/IPubdataChunkPublisher.sol";
import {BLOB_SIZE_BYTES, MAX_NUMBER_OF_BLOBS} from "./Constants.sol";
import {TooMuchPubdata} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for chunking pubdata into the appropriate size for EIP-4844 blobs.
 */
contract PubdataChunkPublisher is IPubdataChunkPublisher {
    /// @notice Chunks pubdata into pieces that can fit into blobs.
    /// @param _pubdata The total l2 to l1 pubdata that will be sent via L1 blobs.
    /// @dev Note: This is an early implementation, in the future we plan to support up to 16 blobs per l1 batch.
    function chunkPubdataToBlobs(bytes calldata _pubdata) external pure returns (bytes32[] memory blobLinearHashes) {
        if (_pubdata.length > BLOB_SIZE_BYTES * MAX_NUMBER_OF_BLOBS) {
            revert TooMuchPubdata(BLOB_SIZE_BYTES * MAX_NUMBER_OF_BLOBS, _pubdata.length);
        }

        // `+BLOB_SIZE_BYTES-1` is used to round up the division.
        uint256 blobCount = (_pubdata.length + BLOB_SIZE_BYTES - 1) / BLOB_SIZE_BYTES;

        blobLinearHashes = new bytes32[](blobCount);

        // We allocate to the full size of blobCount * BLOB_SIZE_BYTES because we need to pad
        // the data on the right with 0s if it doesn't take up the full blob
        bytes memory totalBlobs = new bytes(BLOB_SIZE_BYTES * blobCount);

        assembly {
            // The pointer to the allocated memory above. We skip 32 bytes to avoid overwriting the length.
            let ptr := add(totalBlobs, 0x20)
            calldatacopy(ptr, _pubdata.offset, _pubdata.length)
        }

        for (uint256 i = 0; i < blobCount; ++i) {
            uint256 start = BLOB_SIZE_BYTES * i;

            bytes32 blobHash;
            assembly {
                // The pointer to the allocated memory above skipping the length.
                let ptr := add(totalBlobs, 0x20)
                blobHash := keccak256(add(ptr, start), BLOB_SIZE_BYTES)
            }

            blobLinearHashes[i] = blobHash;
        }
    }
}
