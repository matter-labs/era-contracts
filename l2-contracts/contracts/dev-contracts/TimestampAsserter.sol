// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


interface ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) external view;
}

contract TimestampAsserter is ITimestampAsserter {
    // Minimum interval that the end of the time window should be ahead of the block.timestamp in seconds
    uint256 public constant MIN_INTERVAL = 60;
    // Minimum difference between time window start and end in seconds
    uint256 public constant MIN_DIFFERENCE = 100;

    function assertTimestampInRange(uint256 start, uint256 end) public view {
        require(end >= start + MIN_DIFFERENCE, "Time window end must be at least 100 seconds after the time window start");
        require(end >= block.timestamp + MIN_INTERVAL, "Time window end must be at least 60 seconds after the current block time");
    }
}