// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IPubdataChunkPublisher} from "./interfaces/IPubdataChunkPublisher.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {L1_MESSENGER_CONTRACT, BLOB_SIZE_BYTES} from "./Constants.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for chunking pubdata into the appropriate size for 4844 blobs.
 */
contract PubdataChunkPublisher is IPubdataChunkPublisher, ISystemContract {
    /// @notice Chunks pubdata into pieces that can fit into blobs.
    /// @param _pubdata The total l2 to l1 pubdata that will be sent via L1 blobs.
    /// @return blobHashes Array of hashes corresponding to each blob being published.
    /// @dev Note: This is an early implementation, in the future we plan to support up to 16 blobs per l1 batch.
    function chunkAndPublishPubdata(
        bytes calldata _pubdata
    ) external view onlyCallFrom(address(L1_MESSENGER_CONTRACT)) returns (bytes32[] memory blobHashes) {
        require(_pubdata.length <= BLOB_SIZE_BYTES * 2, "pubdata should fit in 2 blobs");
        // ToDo: Update for dynamic number of hashes: 
        //       blobHashes = new bytes32[]((_pubdata.length / BLOB_SIZE_BYTES) + 1);
        blobHashes = new bytes32[](2);
        for (uint256 i = 0; i < _pubdata.length; i += BLOB_SIZE_BYTES) {
            uint256 end = i + BLOB_SIZE_BYTES > _pubdata.length ? _pubdata.length : i + BLOB_SIZE_BYTES;

            bytes calldata blob = _pubdata[i:end];
            bytes32 blobHash = EfficientCall.keccak(blob);

            blobHashes[i / BLOB_SIZE_BYTES] = blobHash;
        }
    }
}
