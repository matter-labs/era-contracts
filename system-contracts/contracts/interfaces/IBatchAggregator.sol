// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

uint256 constant COMPRESSED_STATE_DIFF_SIZE = 64;

interface IBatchAggregator {
    function commitBatch(
        bytes calldata _totalL2ToL1PubdataAndStateDiffs,
        uint256 chainId,
        uint256 batchNumber
    ) external;
    function returnBatchesAndClearState() external returns (bytes memory);
}
