// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {L2Log} from "../../common/Messaging.sol";
// solhint-disable-next-line no-unused-import
import {MAX_NUMBER_OF_BLOBS, SystemLogKey} from "system-contracts/contracts/Constants.sol";

struct LogProcessingOutput {
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
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
}
