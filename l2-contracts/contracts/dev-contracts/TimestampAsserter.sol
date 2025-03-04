// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ITimestampAsserter} from "./ITimestampAsserter.sol";

error TimestampOutOfRange(uint256 currentTimestamp, uint256 start, uint256 end);

/// @title TimestampAsserter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev A contract that verifies if the current block timestamp falls within a specified range.
/// This is useful for custom account abstraction where time-bound checks are needed but accessing block.timestamp
/// directly is not possible.
contract TimestampAsserter is ITimestampAsserter {
    function assertTimestampInRange(uint256 _start, uint256 _end) external view {
        if (block.timestamp < _start || block.timestamp > _end) {
            revert TimestampOutOfRange(block.timestamp, _start, _end);
        }
    }
}
