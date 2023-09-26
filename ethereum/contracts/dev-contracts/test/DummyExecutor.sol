// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../proof-system/chain-interfaces/IExecutor.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyExecutor is IProofExecutor {
    address owner;

    // Flags to control if the contract should revert during commit, prove, and execute blocks operations
    bool shouldRevertOnCommitBlocks;
    bool shouldRevertOnProveBlocks;
    bool shouldRevertOnExecuteBlocks;

    // Counters to track the total number of committed, verified, and executed blocks
    uint256 public getTotalBlocksCommitted;
    uint256 public getTotalBlocksVerified;
    uint256 public getTotalBlocksExecuted;
    string public constant getName = "DummyExecutor";

    /// @notice Constructor sets the contract owner to the message sender
    constructor() {
        owner = msg.sender;
    }

    /// @notice Modifier that only allows the owner to call certain functions
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    /// @notice Removing txs from the priority queue
    function removePriorityQueueFront(uint256 _index) external {
        // KL todo
        // s.priorityQueue.removeFront(_index);
    }

    /// @notice Allows the owner to set whether the contract should revert during commit blocks operation
    function setShouldRevertOnCommitBlocks(bool _shouldRevert) external onlyOwner {
        shouldRevertOnCommitBlocks = _shouldRevert;
    }

    /// @notice Allows the owner to set whether the contract should revert during prove blocks operation
    function setShouldRevertOnProveBlocks(bool _shouldRevert) external onlyOwner {
        shouldRevertOnProveBlocks = _shouldRevert;
    }

    /// @notice Allows the owner to set whether the contract should revert during execute blocks operation
    function setShouldRevertOnExecuteBlocks(bool _shouldRevert) external onlyOwner {
        shouldRevertOnExecuteBlocks = _shouldRevert;
    }

    function commitBlocks(
        StoredBlockInfo calldata _lastCommittedBlockData,
        CommitBlockInfo[] calldata _newBlocksData
    ) external {
        require(!shouldRevertOnCommitBlocks, "DummyExecutor: shouldRevertOnCommitBlocks");
        require(
            _lastCommittedBlockData.blockNumber == getTotalBlocksCommitted,
            "DummyExecutor: Invalid last committed block number"
        );

        uint256 blocksLength = _newBlocksData.length;
        for (uint256 i = 0; i < blocksLength; ++i) {
            require(getTotalBlocksCommitted + i + 1 == _newBlocksData[i].blockNumber);
        }

        getTotalBlocksCommitted += blocksLength;
    }

    function proveBlocks(
        StoredBlockInfo calldata _prevBlock,
        StoredBlockInfo[] calldata _committedBlocks,
        ProofInput calldata
    ) external {
        require(!shouldRevertOnProveBlocks, "DummyExecutor: shouldRevertOnProveBlocks");
        require(_prevBlock.blockNumber == getTotalBlocksVerified, "DummyExecutor: Invalid previous block number");

        require(_committedBlocks.length == 1, "DummyExecutor: Can prove only one block");
        require(
            _committedBlocks[0].blockNumber == _prevBlock.blockNumber + 1,
            "DummyExecutor: Can't prove block out of order"
        );

        getTotalBlocksVerified += 1;
        require(
            getTotalBlocksVerified <= getTotalBlocksCommitted,
            "DummyExecutor: prove more blocks than were committed"
        );
    }

    function executeBlocks(StoredBlockInfo[] calldata _blocksData) external {
        require(!shouldRevertOnExecuteBlocks, "DummyExecutor: shouldRevertOnExecuteBlocks");
        uint256 nBlocks = _blocksData.length;
        for (uint256 i = 0; i < nBlocks; ++i) {
            require(_blocksData[i].blockNumber == getTotalBlocksExecuted + i + 1);
        }
        getTotalBlocksExecuted += nBlocks;
        require(
            getTotalBlocksExecuted <= getTotalBlocksVerified,
            "DummyExecutor: Can't execute blocks more than committed and proven currently"
        );
    }

    function revertBlocks(uint256 _newLastBlock) external {
        require(
            getTotalBlocksCommitted > _newLastBlock,
            "DummyExecutor: The last committed block is less than new last block"
        );
        uint256 newTotalBlocksCommitted = _maxU256(_newLastBlock, getTotalBlocksExecuted);

        if (newTotalBlocksCommitted < getTotalBlocksVerified) {
            getTotalBlocksVerified = newTotalBlocksCommitted;
        }
        getTotalBlocksCommitted = newTotalBlocksCommitted;
    }

    /// @notice Returns larger of two values
    function _maxU256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? b : a;
    }
}
