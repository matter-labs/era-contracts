// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IChainBase.sol";

interface IChainExecutor is IChainBase {
    function executeBlocks() external;

    /// @notice Removing txs from the priority queue
    function addL2Logs(uint256 _index, bytes32 _l2LogsRootHashes) external;

    /// @notice Removing txs from the priority queue
    function collectOperationsFromPriorityQueue(uint256 _index) external returns (bytes32);
}
