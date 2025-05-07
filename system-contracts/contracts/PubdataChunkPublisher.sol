// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPubdataChunkPublisher} from "./interfaces/IPubdataChunkPublisher.sol";
import {BLOB_SIZE_BYTES, MAX_NUMBER_OF_BLOBS} from "./Constants.sol";
import {TooMuchPubdata} from "./SystemContractErrors.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for chunking pubdata into the appropriate size for EIP-4844 blobs.
 */
contract PubdataChunkPublisher is IPubdataChunkPublisher {
    /// @notice Chunks pubdata into pieces that can fit into blobs.
    /// @param _pubdata The total l2 to l1 pubdata that will be sent via L1 blobs.
    /// @dev Note: This is an early implementation, in the future we plan to support up to 16 blobs per l1 batch.
    function chunkPubdataToBlobs(bytes calldata _pubdata) external view returns (bytes32[] memory blobLinearHashes) {
        if (_pubdata.length > BLOB_SIZE_BYTES * MAX_NUMBER_OF_BLOBS) {
            revert TooMuchPubdata(BLOB_SIZE_BYTES * MAX_NUMBER_OF_BLOBS, _pubdata.length);
        }

        // `+BLOB_SIZE_BYTES-1` is used to round up the division.
        uint256 blobCount = (_pubdata.length + BLOB_SIZE_BYTES - 1) / BLOB_SIZE_BYTES;

        blobLinearHashes = new bytes32[](blobCount);

        uint256 ptr;
        for (uint256 i = 0; i < blobCount; ++i) {
            if (ptr + BLOB_SIZE_BYTES <= _pubdata.length) {
                // Pass chunk by pointer since we don't need to pad it
                blobLinearHashes[i] = EfficientCall.keccak(_pubdata[ptr:ptr + BLOB_SIZE_BYTES]);
            } else {
                // Copy to memory to pad with zeroes
                bytes memory blob = new bytes(BLOB_SIZE_BYTES);
                assembly {
                    calldatacopy(add(0x20, blob), add(_pubdata.offset, ptr), sub(_pubdata.length, ptr))
                }
                blobLinearHashes[i] = keccak256(blob);
            }

            ptr = ptr + BLOB_SIZE_BYTES;
        }
    }
}
