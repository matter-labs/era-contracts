// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {L2Log} from "../../common/Messaging.sol";
import {L2DACommitmentScheme} from "../../common/Config.sol";

/// @dev Enum used by L2 System Contracts to differentiate logs.
enum SystemLogKey {
    L2_TO_L1_LOGS_TREE_ROOT_KEY,
    PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
    CHAINED_PRIORITY_TXN_HASH_KEY,
    NUMBER_OF_LAYER_1_TXS_KEY,
    // Note, that it is important that `PREV_BATCH_HASH_KEY` has position
    // `4` since it is the same as it was in the previous protocol version and
    // it is the only one that is emitted before the system contracts are upgraded.
    PREV_BATCH_HASH_KEY,
    L2_DA_VALIDATOR_OUTPUT_HASH_KEY,
    USED_L2_DA_VALIDATOR_ADDRESS_KEY,
    MESSAGE_ROOT_ROLLING_HASH_KEY,
    L2_TXS_STATUS_ROLLING_HASH_KEY,
    SETTLEMENT_LAYER_CHAIN_ID_KEY,
    EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY
}

struct LogProcessingOutput {
    uint256 numberOfLayer1Txs;
    bytes32 chainedPriorityTxsHash;
    bytes32 previousBatchHash;
    bytes32 pubdataHash;
    bytes32 stateDiffHash;
    bytes32 l2LogsTreeRoot;
    uint256 packedBatchAndL2BlockTimestamp;
    bytes32 l2DAValidatorOutputHash;
    bytes32 l2TxsStatusRollingHash;
    bytes32 dependencyRootsRollingHash;
}

/// @dev Maximal value that SystemLogKey variable can have.
uint256 constant MAX_LOG_KEY = uint256(type(SystemLogKey).max);

/// @notice The struct passed to the assetTracker for processing L2 logs and collecting settlement fees.
/// @param logs The L2 logs from the batch.
/// @param messages The L2 messages corresponding to the logs. Note: there can be fewer messages than logs,
///        as not all logs have corresponding messages.
/// @param chainId The chain ID of the settling chain.
/// @param batchNumber The batch number being processed.
/// @param chainBatchRoot The batch root hash for verification.
/// @param messageRoot The message root hash for verification.
/// @param settlementFeePayer Address that pays gateway settlement fees for interop calls in this batch.
///
/// @dev Settlement Fee Payer Requirements:
///      1. Must have called `agreeToPaySettlementFees(chainId)` on GWAssetTracker to opt-in for this specific chain
///      2. Must have sufficient wrapped ZK token balance to cover: gatewaySettlementFee * chargeableInteropCount
///      3. Must have approved GWAssetTracker to spend wrapped ZK tokens
///      The opt-in mechanism prevents front-running attacks where a malicious operator could
///      make another address pay for their chain's settlements by specifying it as settlementFeePayer.
///
/// @dev Failure Behavior:
///      - If fee collection fails (payer not agreed, insufficient balance, or no approval), batch execution reverts
///      - This ensures fees are always paid atomically with settlement
///      - Operators must ensure their fee payer has agreed and maintains sufficient balance/approval
struct ProcessLogsInput {
    L2Log[] logs;
    bytes[] messages;
    uint256 chainId;
    uint256 batchNumber;
    bytes32 chainBatchRoot;
    bytes32 messageRoot;
    address settlementFeePayer;
}

/// @dev Offset used to pull Address From Log. Equal to 4 (bytes for shardId, isService and txNumberInBatch)
uint256 constant L2_LOG_ADDRESS_OFFSET = 4;

/// @dev Offset used to pull Key From Log. Equal to 4 (bytes for shardId, isService and txNumberInBatch) + 20 (bytes for address)
uint256 constant L2_LOG_KEY_OFFSET = 24;

/// @dev Offset used to pull Value From Log. Equal to 4 (bytes for shardId, isService and txNumberInBatch) + 20 (bytes for address) + 32 (bytes for key)
uint256 constant L2_LOG_VALUE_OFFSET = 56;

/// @dev Max number of blobs currently supported
uint256 constant MAX_NUMBER_OF_BLOBS = 6;

/// @dev The number of blobs that must be present in the commitment to a batch.
/// It represents the maximal number of blobs that circuits can support and can be larger
/// than the maximal number of blobs supported by the contract (`MAX_NUMBER_OF_BLOBS`).
uint256 constant TOTAL_BLOBS_IN_COMMITMENT = 16;

/// @title The interface of the ZKsync Executor contract capable of processing events emitted in the ZKsync protocol.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IExecutor is IZKChainBase {
    /// @notice Rollup batch stored data, this structure used for both: Era VM and ZKsync OS batches, however some fields have different meaning
    /// @param batchNumber Rollup batch number
    /// @param batchHash Hash of L2 batch, for ZKsync OS batches we'll store here full state commitment
    /// @param indexRepeatedStorageChanges The serial number of the shortcut index that's used as a unique identifier for storage keys that were used twice or more. For ZKsync OS not used, always set to 0
    /// @param numberOfLayer1Txs Number of priority operations to be processed
    /// @param priorityOperationsHash Hash of all priority operations from this batch
    /// @param l2LogsTreeRoot Root hash of tree that contains L2 -> L1 messages from this batch
    /// @param timestamp Rollup batch timestamp, have the same format as Ethereum batch constant. For ZKsync OS not used, always set to 0
    /// @param commitment Verified input for the ZKsync circuit. For ZKsync OS batches we'll store batch output hash here
    // solhint-disable-next-line gas-struct-packing
    struct StoredBatchInfo {
        uint64 batchNumber;
        bytes32 batchHash; // For ZKsync OS batches we'll store here full state commitment
        uint64 indexRepeatedStorageChanges; // For ZKsync OS not used, always set to 0
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 dependencyRootsRollingHash;
        bytes32 l2LogsTreeRoot;
        uint256 timestamp; // For ZKsync OS not used, always set to 0
        bytes32 commitment; // For ZKsync OS batches we'll store batch output hash here
    }

    /// @notice Legacy StoredBatchInfo struct
    /// @dev dependencyRootsRollingHash is not included in the struct
    // solhint-disable-next-line gas-struct-packing
    struct LegacyStoredBatchInfo {
        uint64 batchNumber;
        bytes32 batchHash;
        uint64 indexRepeatedStorageChanges;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 l2LogsTreeRoot;
        uint256 timestamp;
        bytes32 commitment;
    }

    /// @notice Data needed to commit new batch
    /// @param batchNumber Number of the committed batch
    /// @param timestamp Unix timestamp denoting the start of the batch execution
    /// @param indexRepeatedStorageChanges The serial number of the shortcut index that's used as a unique identifier for storage keys that were used twice or more
    /// @param newStateRoot The state root of the full state tree
    /// @param numberOfLayer1Txs Number of priority operations to be processed
    /// @param priorityOperationsHash Hash of all priority operations from this batch
    /// @param bootloaderHeapInitialContentsHash Hash of the initial contents of the bootloader heap. In practice it serves as the commitment to the transactions in the batch.
    /// @param eventsQueueStateHash Hash of the events queue state. In practice it serves as the commitment to the events in the batch.
    /// @param systemLogs concatenation of all L2 -> L1 system logs in the batch
    /// @param operatorDAInput Packed pubdata commitments/data.
    /// @dev pubdataCommitments format: This will always start with a 1 byte pubdataSource flag. Current allowed values are 0 (calldata) or 1 (blobs)
    ///                             kzg: list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes) = 144 bytes
    ///                             calldata: pubdataCommitments.length - 1 - 32 bytes of pubdata
    ///                                       and 32 bytes appended to serve as the blob commitment part for the aux output part of the batch commitment
    /// @dev For 2 blobs we will be sending 288 bytes of calldata instead of the full amount for pubdata.
    /// @dev When using calldata, we only need to send one blob commitment since the max number of bytes in calldata fits in a single blob and we can pull the
    ///     linear hash from the system logs
    struct CommitBatchInfo {
        uint64 batchNumber;
        uint64 timestamp;
        uint64 indexRepeatedStorageChanges;
        bytes32 newStateRoot;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 bootloaderHeapInitialContentsHash;
        bytes32 eventsQueueStateHash;
        bytes systemLogs;
        bytes operatorDAInput;
    }

    /// @notice Commit batch info for ZKsync OS
    /// @param batchNumber Number of the committed batch
    /// @param newStateCommitment State commitment of the new state.
    /// @dev chain state commitment, this preimage is not opened on l1,
    /// it's guaranteed that this commitment commits to any state that needed for execution
    /// (state root, block number, block hashes)
    /// @param numberOfLayer1Txs Number of priority operations to be processed
    /// @param priorityOperationsHash Hash of all priority operations from this batch
    /// @param l2LogsTreeRoot Root hash of tree that contains L2 -> L1 messages from this batch
    /// @param daCommitmentScheme commitment scheme used to generate pubdata commitment for this batch
    /// @param daCommitment commitment to the batch pubdata to validate DA in the l1 da validator
    // solhint-disable-next-line gas-struct-packing
    struct CommitBatchInfoZKsyncOS {
        uint64 batchNumber;
        bytes32 newStateCommitment;
        uint256 numberOfLayer1Txs;
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
    }

    /// @notice Container for a list of transaction statuses to precommit.
    /// @param txs A packed array of individual transaction status commitments for the batch. Each is expected to be
    /// of length 33 and have the following format: <32-byte tx hash, 1-byte status>. where status is either 0 (failed) or 1 (success).
    /// @param untrustedLastL2BlockNumberHint The "hint" for what the last L2 block number that these txs represent is.
    struct PrecommitInfo {
        bytes packedTxsCommitments;
        uint256 untrustedLastL2BlockNumberHint;
    }

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

    /// @notice Batches commitment verification.
    /// @dev Only verifies batch commitments without any other processing.
    /// @param _chainAddress The address of the DiamondProxy of the chain. Note, that it is not used in the implementation,
    /// because it is expected to be equal to the `address(this)`, but it is kept here to maintain the same interface on both
    /// `ValidatorTimelock` and `Executor` for easier and cheaper implementation of the timelock.
    /// @param _processBatchFrom The batch number from which the verification starts.
    /// @param _processBatchTo The batch number at which the verification ends.
    /// @param _proofData The encoded data of the new batches to be verified.
    function proveBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _proofData
    ) external;

    /// @notice The function called by the operator to finalize (execute) batches. It is responsible for:
    /// - Processing all pending operations (commpleting priority requests).
    /// - Finalizing this batch (i.e. allowing to withdraw funds from the system)
    /// @param _chainAddress The address of the DiamondProxy of the chain. Note, that it is not used in the implementation,
    /// because it is expected to be equal to the `address(this)`, but it is kept here to maintain the same interface on both
    /// `ValidatorTimelock` and `Executor` for easier and cheaper implementation of the timelock.
    /// @param _processFrom The batch number from which the execution starts.
    /// @param _processTo The batch number at which the execution ends.
    /// @param _executeData The encoded data of the new batches to be executed. Contains settlement fee payer address.
    function executeBatchesSharedBridge(
        address _chainAddress,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external;

    /// @notice Reverts unexecuted batches
    /// @param _chainAddress The address of the DiamondProxy of the chain.
    /// @param _newLastBatch batch number after which batches should be reverted
    /// @dev When the _newLastBatch is equal to the number of committed batches,
    /// only the precommitment is erased.
    /// NOTE: Doesn't delete the stored data about batches, but only decreases
    /// counters that are responsible for the number of batches
    function revertBatchesSharedBridge(address _chainAddress, uint256 _newLastBatch) external;

    /// @notice Event emitted when a batch is committed
    /// @param batchNumber Number of the batch committed
    /// @param batchHash Hash of the L2 batch
    /// @param commitment Calculated input for the ZKsync circuit
    /// @dev It has the name "BlockCommit" and not "BatchCommit" due to backward compatibility considerations
    event BlockCommit(uint256 indexed batchNumber, bytes32 indexed batchHash, bytes32 indexed commitment);

    /// @notice Event emitted when batches are verified
    /// @param previousLastVerifiedBatch Batch number of the previous last verified batch
    /// @param currentLastVerifiedBatch Batch number of the current last verified batch
    /// @dev It has the name "BlocksVerification" and not "BatchesVerification" due to backward compatibility considerations
    event BlocksVerification(uint256 indexed previousLastVerifiedBatch, uint256 indexed currentLastVerifiedBatch);

    /// @notice Event emitted when a batch is executed
    /// @param batchNumber Number of the batch executed
    /// @param batchHash Hash of the L2 batch
    /// @param commitment Verified input for the ZKsync circuit
    /// @dev It has the name "BlockExecution" and not "BatchExecution" due to backward compatibility considerations
    event BlockExecution(uint256 indexed batchNumber, bytes32 indexed batchHash, bytes32 indexed commitment);

    /// @notice Event emitted when batches are reverted
    /// @param totalBatchesCommitted Total number of committed batches after the revert
    /// @param totalBatchesVerified Total number of verified batches after the revert
    /// @param totalBatchesExecuted Total number of executed batches
    /// @dev It has the name "BlocksRevert" and not "BatchesRevert" due to backward compatibility considerations
    event BlocksRevert(uint256 totalBatchesCommitted, uint256 totalBatchesVerified, uint256 totalBatchesExecuted);

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
