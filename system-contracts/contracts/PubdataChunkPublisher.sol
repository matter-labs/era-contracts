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
    /// @return blobLinearHash A linear hash of the pubdata chunks.
    function chunkAndPublishPubdata(
        bytes calldata _pubdata
    ) external view onlyCallFrom(address(L1_MESSENGER_CONTRACT)) returns (bytes32 blobLinearHash) {
        require(_pubdata.length <= BLOB_SIZE_BYTES * 3, "pubdata should fit in 3 blobs");
        for (uint256 i = 0; i < _pubdata.length; i += BLOB_SIZE_BYTES) {
            uint256 end = i + BLOB_SIZE_BYTES > _pubdata.length ? _pubdata.length : i + BLOB_SIZE_BYTES;

            bytes calldata blob = _pubdata[i:end];
            bytes32 blobHash = EfficientCall.keccak(blob);

            blobLinearHash = keccak256(abi.encode(blobLinearHash, blobHash));
        }
    }
}
