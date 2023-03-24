// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IExecutor {
    /// @notice Rollup block stored data
    /// @param blockNumber Rollup block number
    /// @param blockHash Hash of L2 block
    /// @param indexRepeatedStorageChanges The serial number of the shortcut index that's used as a unique identifier for storage keys that were used twice or more
    /// @param numberOfLayer1Txs Number of priority operations to be processed
    /// @param priorityOperationsHash Hash of all priority operations from this block
    /// @param l2LogsTreeRoot Root hash of tree that contains L2 -> L1 messages from this block
    /// @param timestamp Rollup block timestamp, have the same format as Ethereum block constant
    /// @param commitment Verified input for the zkSync circuit
    struct StoredBlockInfo {
        uint64 blockNumber;
        bytes32 blockHash;
        uint64 indexRepeatedStorageChanges;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 l2LogsTreeRoot;
        uint256 timestamp;
        bytes32 commitment;
    }

    /// @notice Data needed to commit new block
    /// @param blockNumber Number of the committed block
    /// @param timestamp Unix timestamp denoting the start of the block execution
    /// @param indexRepeatedStorageChanges The serial number of the shortcut index that's used as a unique identifier for storage keys that were used twice or more
    /// @param newStateRoot The state root of the full state tree
    /// @param numberOfLayer1Txs Number of priority operations to be processed
    /// @param l2LogsTreeRoot The root hash of the tree that contains all L2 -> L1 logs in the block
    /// @param priorityOperationsHash Hash of all priority operations from this block
    /// @param initialStorageChanges Storage write access as a concatenation key-value
    /// @param repeatedStorageChanges Storage write access as a concatenation index-value
    /// @param l2Logs concatenation of all L2 -> L1 logs in the block
    /// @param l2ArbitraryLengthMessages array of hash preimages that were sent as value of L2 logs by special system L2 contract
    /// @param factoryDeps array of l2 bytecodes that were marked as known on L2
    struct CommitBlockInfo {
        uint64 blockNumber;
        uint64 timestamp;
        uint64 indexRepeatedStorageChanges;
        bytes32 newStateRoot;
        uint256 numberOfLayer1Txs;
        bytes32 l2LogsTreeRoot;
        bytes32 priorityOperationsHash;
        bytes initialStorageChanges;
        bytes repeatedStorageChanges;
        bytes l2Logs;
        bytes[] l2ArbitraryLengthMessages;
        bytes[] factoryDeps;
    }

    /// @notice Recursive proof input data (individual commitments are constructed onchain)
    struct ProofInput {
        uint256[] recursiveAggregationInput;
        uint256[] serializedProof;
    }

    function commitBlocks(StoredBlockInfo calldata _lastCommittedBlockData, CommitBlockInfo[] calldata _newBlocksData)
        external;

    function proveBlocks(
        StoredBlockInfo calldata _prevBlock,
        StoredBlockInfo[] calldata _committedBlocks,
        ProofInput calldata _proof
    ) external;

    function executeBlocks(StoredBlockInfo[] calldata _blocksData) external;

    function revertBlocks(uint256 _newLastBlock) external;

    /// @notice Event emitted when a block is committed
    event BlockCommit(uint256 indexed blockNumber, bytes32 indexed blockHash, bytes32 indexed commitment);

    /// @notice Event emitted when blocks are verified
    event BlocksVerification(uint256 indexed previousLastVerifiedBlock, uint256 indexed currentLastVerifiedBlock);

    /// @notice Event emitted when a block is executed
    event BlockExecution(uint256 indexed blockNumber, bytes32 indexed blockHash, bytes32 indexed commitment);

    /// @notice Event emitted when blocks are reverted
    event BlocksRevert(uint256 totalBlocksCommitted, uint256 totalBlocksVerified, uint256 totalBlocksExecuted);
}
