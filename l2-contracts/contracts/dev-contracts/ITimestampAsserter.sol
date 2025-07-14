// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ITimestampAsserter {
    function assertTimestampInRange(uint256 start, uint256 end) external view;
}
