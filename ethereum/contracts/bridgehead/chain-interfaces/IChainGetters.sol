// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-deps/ChainStorage.sol";
import "../libraries/PriorityQueue.sol";
import "./IChainBase.sol";

interface IChainGetters is IChainBase {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    function getGovernor() external view returns (address);

    function getPendingGovernor() external view returns (address);

    function getTotalBlocksExecuted() external view returns (uint256);

    function getTotalPriorityTxs() external view returns (uint256);

    function getFirstUnprocessedPriorityTx() external view returns (uint256);

    function getPriorityQueueSize() external view returns (uint256);

    function priorityQueueFrontOperation() external view returns (PriorityOperation memory);

    function l2LogsRootHash(uint256 _blockNumber) external view returns (bytes32 hash);

    function isEthWithdrawalFinalized(uint256 _l2BlockNumber, uint256 _l2MessageIndex) external view returns (bool);

    function getPriorityTxMaxGasLimit() external view returns (uint256);

    function getAllowList() external view returns (address);
}
