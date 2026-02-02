// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {IExecutor} from "./IExecutor.sol";

/// @title The interface of the ZKsync Committer contract responsible for batch commitment operations.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ICommitter is IZKChainBase {
    /// @notice Precommits the status of all L2 transactions for the next batch on the shared bridge.
    /// @param _chainAddress The address of the DiamondProxy of the chain. Note, that it is not used in the implementation,
    /// because it is expected to be equal to the `address(this)`, but it is kept here to maintain the same interface on both
    /// `ValidatorTimelock` and `Executor` for easier and cheaper implementation of the timelock.
    /// @param _batchNumber The sequential batch number to precommit (must equal `s.totalBatchesCommitted + 1`).
    /// @param _precommitData ABI‐encoded transaction status list for the precommit.
    function precommitSharedBridge(address _chainAddress, uint256 _batchNumber, bytes calldata _precommitData) external;

    /// @notice Function called by the operator to commit new batches. It is responsible for:
    /// - Verifying the correctness of their timestamps.
    /// - Processing their L2->L1 logs.
    /// - Storing batch commitments.
    /// @param _chainAddress The address of the DiamondProxy of the chain. Note, that it is not used in the implementation,
    /// because it is expected to be equal to the `address(this)`, but it is kept here to maintain the same interface on both
    /// `ValidatorTimelock` and `Executor` for easier and cheaper implementation of the timelock.
    /// @param _processFrom The batch number from which the processing starts.
    /// @param _processTo The batch number at which the processing ends.
    /// @param _commitData The encoded data of the new batches to be committed.
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) external;

    /// @notice Event emitted when a batch is committed
    /// @param batchNumber Number of the batch committed
    /// @param batchHash Hash of the L2 batch
    /// @param commitment Calculated input for the ZKsync circuit
    /// @dev It has the name "BlockCommit" and not "BatchCommit" due to backward compatibility considerations
    event BlockCommit(uint256 indexed batchNumber, bytes32 indexed batchHash, bytes32 indexed commitment);

    /// @notice Emitted when a new precommitment is set for a batch.
    /// @param batchNumber The batch number for which the precommitment was recorded.
    /// @param untrustedLastL2BlockNumberHint The hint to what L2 block number the precommitment should correspond to. Note, that there are no
    /// guarantees on its correctness, it is just a way for the server to make external nodes' indexing simpler.
    /// @param precommitment The resulting rolling hash of all transaction statuses.
    event BatchPrecommitmentSet(
        uint256 indexed batchNumber,
        uint256 indexed untrustedLastL2BlockNumberHint,
        bytes32 precommitment
    );

    /// @notice Reports the block range for a zksync os batch.
    /// @dev IMPORTANT: in this release this range is not trusted and provided by the operator while not being included to the proof.
    event ReportCommittedBatchRangeZKsyncOS(
        uint64 indexed batchNumber,
        uint64 indexed firstBlockNumber,
        uint64 indexed lastBlockNumber
    );
}
