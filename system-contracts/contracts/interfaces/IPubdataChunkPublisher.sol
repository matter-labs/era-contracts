// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPubdataChunkPublisher {
    /// @notice Chunks pubdata into pieces that can fit into blobs.
    /// @param _pubdata The total l2 to l1 pubdata that will be sent via L1 blobs.
    /// @return blobLinearHash A linear hash of the pubdata chunks.
    function chunkAndPublishPubdata(bytes calldata _pubdata) external view returns (bytes32 blobLinearHash);
}
