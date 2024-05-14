// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IBatchAggregator{
    function commitBatch(bytes memory batch) external;
    function returnBatchesAndClearState() external returns (bytes memory);
}