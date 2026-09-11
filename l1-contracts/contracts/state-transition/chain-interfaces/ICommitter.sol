// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {L2DACommitmentScheme} from "../../common/Config.sol";

/// @notice Commit batch info for ZKsync OS
/// @param batchNumber Number of the committed batch
/// @param newStateCommitment State commitment of the new state.
/// @dev chain state commitment, this preimage is not opened on l1,
/// it's guaranteed that this commitment commits to any state that needed for execution
/// (state root, block number, block hashes)
/// @param numberOfLayer1Txs Number of priority operations to be processed
/// @param numberOfLayer2Txs Number of L2 transactions executed in the batch
/// @param priorityOperationsHash Hash of all priority operations from this batch
/// @param l2LogsTreeRoot Root hash of tree that contains L2 -> L1 messages from this batch
/// @param daCommitmentScheme commitment scheme used to generate pubdata commitment for this batch
/// @param daCommitment commitment to the batch pubdata to validate DA in the l1 da validator
// solhint-disable-next-line gas-struct-packing
struct CommitBatchInfoZKsyncOS {
    uint64 batchNumber;
    bytes32 newStateCommitment;
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;
    L2DACommitmentScheme daCommitmentScheme;
    bytes32 daCommitment;
    uint64 firstBlockTimestamp;
    uint64 firstBlockNumber;
    uint64 lastBlockTimestamp;
    uint64 lastBlockNumber;
    uint256 chainId;
    bytes operatorDAInput;
    uint256 slChainId;
}

/// @title The interface of the ZKsync Committer contract responsible for batch commitment operations.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ICommitter is IZKChainBase {
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

    /// @notice Reports the protocol version a batch was committed with, together with the system upgrade
    /// transaction hash applied in that batch (if any).
    /// @dev Emitted for every committed batch. The `upgradeTxHash` is additionally folded into the
    /// batch commitment, enabling independent recomputation of the commitment.
    /// @param batchNumber Number of the batch committed.
    /// @param protocolVersion The protocol version the batch was committed with.
    /// @param upgradeTxHash Hash of the system upgrade transaction applied in this batch; non-zero only for
    /// the first batch committed after a protocol upgrade.
    event ReportCommittedBatchProtocolVersion(
        uint64 indexed batchNumber,
        uint256 indexed protocolVersion,
        bytes32 indexed upgradeTxHash
    );

    /// @notice Reports the block range for a zksync os batch.
    /// @dev IMPORTANT: in this release this range is not trusted and provided by the operator while not being included to the proof.
    event ReportCommittedBatchRangeZKsyncOS(
        uint64 indexed batchNumber,
        uint64 indexed firstBlockNumber,
        uint64 indexed lastBlockNumber
    );
}
