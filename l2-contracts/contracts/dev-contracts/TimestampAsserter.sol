// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) external view;
}

contract TimestampAsserter is ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) public view {
        require(
            start <= block.timestamp && block.timestamp <= end,
            "Block timestamp is outside of the specified range"
        );
    }
}
