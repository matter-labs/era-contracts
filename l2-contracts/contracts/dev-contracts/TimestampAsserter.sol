// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) external view;
}

error TimestampOutOfRange();

contract TimestampAsserter is ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) public view {
        if (start > block.timestamp || end < block.timestamp)
            revert TimestampOutOfRange();
    }
}
