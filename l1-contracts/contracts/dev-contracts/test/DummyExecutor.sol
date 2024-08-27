// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IExecutor} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {PriorityOpsBatchInfo} from "../../state-transition/libraries/PriorityTree.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyExecutor is IExecutor {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    address owner;

    // Flags to control if the contract should revert during commit, prove, and execute batch operations
    bool shouldRevertOnCommitBatches;
    bool shouldRevertOnProveBatches;
    bool shouldRevertOnExecuteBatches;

    // Counters to track the total number of committed, verified, and executed batches
    uint256 public getTotalBatchesCommitted;
    uint256 public getTotalBatchesVerified;
    uint256 public getTotalBatchesExecuted;
    string public constant override getName = "DummyExecutor";

    /// @notice Constructor sets the contract owner to the message sender
    constructor() {
        owner = msg.sender;
    }

    /// @notice Modifier that only allows the owner to call certain functions
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    function getAdmin() external view returns (address) {
        return owner;
    }

    /// @notice Removing txs from the priority queue
    function removePriorityQueueFront(uint256 _index) external {}

    /// @notice Allows the owner to set whether the contract should revert during commit blocks operation
    function setShouldRevertOnCommitBatches(bool _shouldRevert) external onlyOwner {
        shouldRevertOnCommitBatches = _shouldRevert;
    }

    /// @notice Allows the owner to set whether the contract should revert during prove batches operation
    function setShouldRevertOnProveBatches(bool _shouldRevert) external onlyOwner {
        shouldRevertOnProveBatches = _shouldRevert;
    }

    /// @notice Allows the owner to set whether the contract should revert during execute batches operation
    function setShouldRevertOnExecuteBatches(bool _shouldRevert) external onlyOwner {
        shouldRevertOnExecuteBatches = _shouldRevert;
    }

    function commitBatchesSharedBridge(
        uint256,
        StoredBatchInfo calldata _lastCommittedBatchData,
        CommitBatchInfo[] calldata _newBatchesData
    ) external {
        require(!shouldRevertOnCommitBatches, "DummyExecutor: shouldRevertOnCommitBatches");
        require(
            _lastCommittedBatchData.batchNumber == getTotalBatchesCommitted,
            "DummyExecutor: Invalid last committed batch number"
        );

        uint256 batchesLength = _newBatchesData.length;
        for (uint256 i = 0; i < batchesLength; ++i) {
            require(getTotalBatchesCommitted + i + 1 == _newBatchesData[i].batchNumber);
        }

        getTotalBatchesCommitted += batchesLength;
    }

    function proveBatchesSharedBridge(
        uint256,
        StoredBatchInfo calldata _prevBatch,
        StoredBatchInfo[] calldata _committedBatches,
        ProofInput calldata _proof
    ) external {
        require(!shouldRevertOnProveBatches, "DummyExecutor: shouldRevertOnProveBatches");
        require(_prevBatch.batchNumber == getTotalBatchesVerified, "DummyExecutor: Invalid previous batch number");

        require(_committedBatches.length == 1, "DummyExecutor: Can prove only one batch");
        require(
            _committedBatches[0].batchNumber == _prevBatch.batchNumber + 1,
            "DummyExecutor 1: Can't prove batch out of order"
        );

        getTotalBatchesVerified += 1;
        require(
            getTotalBatchesVerified <= getTotalBatchesCommitted,
            "DummyExecutor: prove more batches than were committed"
        );
    }

    function executeBatches(StoredBatchInfo[] calldata _batchesData) public {
        require(!shouldRevertOnExecuteBatches, "DummyExecutor: shouldRevertOnExecuteBatches");
        uint256 nBatches = _batchesData.length;
        for (uint256 i = 0; i < nBatches; ++i) {
            require(_batchesData[i].batchNumber == getTotalBatchesExecuted + i + 1);
        }
        getTotalBatchesExecuted += nBatches;
        require(
            getTotalBatchesExecuted <= getTotalBatchesVerified,
            "DummyExecutor 2: Can't execute batches more than committed and proven currently"
        );
    }

    function executeBatchesSharedBridge(uint256, StoredBatchInfo[] calldata _batchesData) external {
        executeBatches(_batchesData);
    }

    function executeBatchesSharedBridge(
        uint256,
        StoredBatchInfo[] calldata _batchesData,
        PriorityOpsBatchInfo[] calldata
    ) external {
        executeBatches(_batchesData);
    }

    function revertBatchesSharedBridge(uint256, uint256 _newLastBatch) external {
        require(
            getTotalBatchesCommitted > _newLastBatch,
            "DummyExecutor: The last committed batch is less than new last batch"
        );
        uint256 newTotalBatchesCommitted = _maxU256(_newLastBatch, getTotalBatchesExecuted);

        if (newTotalBatchesCommitted < getTotalBatchesVerified) {
            getTotalBatchesVerified = newTotalBatchesCommitted;
        }
        getTotalBatchesCommitted = newTotalBatchesCommitted;
    }

    /// @notice Returns larger of two values
    function _maxU256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? b : a;
    }
}
