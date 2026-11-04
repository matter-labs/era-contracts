// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContext} from "../SystemContext.sol";

/**
 * @title SystemContextTest
 * @notice Test contract that makes some of the deprecated functions in SystemContext accessible for testing purposes
 */
contract SystemContextTest is SystemContext {
    /// @notice Returns the number and timestamp of the given batch for testing purposes
    function getBatchNumberAndTimestampTesting() external view returns (uint128 batchNumber, uint128 batchTimestamp) {
        BlockInfo memory batchInfo = currentBatchInfo;
        batchNumber = batchInfo.number;
        batchTimestamp = batchInfo.timestamp;
    }

    /// @notice Returns the hash of the given batch for testing purposes
    function getBatchHashTesting(uint256 _batchNumber) external view returns (bytes32 hash) {
        return batchHashes[_batchNumber];
    }
}
