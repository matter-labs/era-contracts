// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IPubdataChunkPublisher} from "./interfaces/IPubdataChunkPublisher.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {L1_MESSENGER_CONTRACT, BLOB_SIZE_BYTES, EMPTY_BLOB_HASH} from "./Constants.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {SystemLogKey} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for chunking pubdata into the appropriate size for 4844 blobs.
 */
contract PubdataChunkPublisher is IPubdataChunkPublisher, ISystemContract {
    /// @notice Chunks pubdata into pieces that can fit into blobs.
    /// @param _pubdata The total l2 to l1 pubdata that will be sent via L1 blobs.
    /// @dev Note: This is an early implementation, in the future we plan to support up to 16 blobs per l1 batch.
    /// @dev We always publish 2 system logs even if our pubdata fits into a single blob. This makes processing logs on L1 easier.
    function chunkAndPublishPubdata(bytes calldata _pubdata) external onlyCallFrom(address(L1_MESSENGER_CONTRACT)) {
        require(_pubdata.length <= BLOB_SIZE_BYTES * 2, "pubdata should fit in 2 blobs");
        // TODO: Update for dynamic number of blobs
        bytes32 blob1Hash;
        bytes32 blob2Hash;

        assembly {
            // The pointer to the free memory slot
            let ptr := mload(0x40)
            calldatacopy(ptr, _pubdata.offset, _pubdata.length)

            blob1Hash := keccak256(ptr, BLOB_SIZE_BYTES)
            blob2Hash := keccak256(add(ptr, BLOB_SIZE_BYTES), BLOB_SIZE_BYTES)
        }

        blob1Hash = blob1Hash == bytes32(0) ? EMPTY_BLOB_HASH : blob1Hash;
        blob2Hash = blob2Hash == bytes32(0) ? EMPTY_BLOB_HASH : blob2Hash;

        SystemContractHelper.toL1(true, bytes32(uint256(SystemLogKey.BLOB_ONE_HASH_KEY)), blob1Hash);
        SystemContractHelper.toL1(true, bytes32(uint256(SystemLogKey.BLOB_TWO_HASH_KEY)), blob2Hash);
    }
}
