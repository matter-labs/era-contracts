// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "../Config.sol";
import "./ChainBase.sol";
import "../libraries/PriorityQueue.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../chain-interfaces/IChainGetters.sol";

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract ChainGetters is IChainGetters, ChainBase {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return chainStorage.governor;
    }

    /// @return The address of the pending governor
    function getPendingGovernor() external view returns (address) {
        return chainStorage.pendingGovernor;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getChainId() external view returns (uint256) {
        return chainStorage.chainId;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getProofSystem() external view returns (address) {
        return chainStorage.proofSystem;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getTotalBlocksExecuted() external view returns (uint256) {
        return chainStorage.totalBlocksExecuted;
    }

    /// @return The total number of priority operations that were added to the priority queue, including all processed ones
    function getTotalPriorityTxs() external view returns (uint256) {
        return chainStorage.priorityQueue.getTotalPriorityTxs();
    }

    /// @notice Returns zero if and only if no operations were processed from the queue
    /// @notice Reverts if there are no unprocessed priority transactions
    /// @return Index of the oldest priority operation that wasn't processed yet
    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return chainStorage.priorityQueue.getFirstUnprocessedPriorityTx();
    }

    /// @return The number of priority operations currently in the queue
    function getPriorityQueueSize() external view returns (uint256) {
        return chainStorage.priorityQueue.getSize();
    }

    /// @return The first unprocessed priority operation from the queue
    function priorityQueueFrontOperation() external view returns (PriorityOperation memory) {
        return chainStorage.priorityQueue.front();
    }

    /// @return Merkle root of the tree with L2 logs for the selected block
    function l2LogsRootHash(uint256 _blockNumber) external view returns (bytes32) {
        return chainStorage.l2LogsRootHashes[_blockNumber];
    }

    /// @return Whether a withdrawal has been finalized.
    /// @param _l2BlockNumber The L2 block number within which the withdrawal happened.
    /// @param _l2MessageIndex The index of the L2->L1 message denoting the withdrawal.
    function isEthWithdrawalFinalized(uint256 _l2BlockNumber, uint256 _l2MessageIndex) external view returns (bool) {
        return chainStorage.isEthWithdrawalFinalized[_l2BlockNumber][_l2MessageIndex];
    }

    /// @return The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return chainStorage.priorityTxMaxGasLimit;
    }

    /// @return The allow list smart contract
    function getAllowList() external view returns (address) {
        return address(chainStorage.allowList);
    }
}
