// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Entry point of `deploy-scripts/upgrade/v33/RecordPriorityOpLowerBound.s.sol`, driven by
///         `protocol-ops chain record-priority-op-lower-bound`.
/// @dev The v33 per-chain upgrade refuses to run until the chain's priority-op bound has been
///      recorded and every op below it processed, so this is a mandatory prerequisite that has to
///      land in its own transaction well ahead of the diamond cut.
interface IRecordPriorityOpLowerBound {
    function run(address _priorityOpLowerBound, address _bridgehub, uint256 _chainId) external;
}
