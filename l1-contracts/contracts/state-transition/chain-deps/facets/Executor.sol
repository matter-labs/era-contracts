// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBase} from "./ZKChainBase.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IMessageRoot} from "../../../core/message-root/IMessageRoot.sol";
import {COMMIT_TIMESTAMP_APPROXIMATION_DELTA, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE, MAINNET_CHAIN_ID, MAINNET_COMMIT_TIMESTAMP_NOT_OLDER, MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, PACKED_L2_BLOCK_TIMESTAMP_MASK, PACKED_L2_PRECOMMITMENT_LENGTH, PUBLIC_INPUT_SHIFT, TESTNET_COMMIT_TIMESTAMP_NOT_OLDER, DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "../../../common/Config.sol";
import {IExecutor, L2_LOG_ADDRESS_OFFSET, L2_LOG_KEY_OFFSET, L2_LOG_VALUE_OFFSET, LogProcessingOutput, MAX_LOG_KEY, ProcessLogsInput, SystemLogKey, TOTAL_BLOBS_IN_COMMITMENT} from "../../chain-interfaces/IExecutor.sol";
import {BatchDecoder} from "../../libraries/BatchDecoder.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../../common/libraries/UnsafeBytes.sol";
import {GW_ASSET_TRACKER, L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {PriorityOpsBatchInfo, PriorityTree} from "../../libraries/PriorityTree.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "../../chain-interfaces/IL1DAValidator.sol";
import {BatchHashMismatch, BatchNumberMismatch, CanOnlyProcessOneBatch, CantExecuteUnprovenBatches, CantRevertExecutedBatch, EmptyPrecommitData, HashMismatch, IncorrectBatchChainId, InvalidBatchNumber, InvalidLogSender, InvalidMessageRoot, InvalidNumberOfBlobs, InvalidPackedPrecommitmentLength, InvalidProof, InvalidProtocolVersion, InvalidSystemLogsLength, L2TimestampTooBig, LogAlreadyProcessed, MissingSystemLogs, NonIncreasingTimestamp, NonSequentialBatch, PrecommitmentMismatch, PriorityOperationsRollingHashMismatch, RevertedBatchNotAfterNewLastBatch, SystemLogsSizeTooBig, TimeNotReached, TimestampError, TxHashMismatch, UnexpectedSystemLog, UpgradeBatchNumberIsNotZero, ValueMismatch, VerifiedBatchesExceedsCommittedBatches, NonZeroBlobToVerifyZKsyncOS, InvalidBlockRange} from "../../../common/L1ContractErrors.sol";
import {CommitBasedInteropNotSupported, DependencyRootsRollingHashMismatch, InvalidBatchesDataLength, MessageRootIsZero, MismatchL2DACommitmentScheme, MismatchNumberOfLayer1Txs, SettlementLayerChainIdMismatch} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";
import {InteropRoot, L2Log} from "../../../common/Messaging.sol";

/// @dev The version that is used for the `Executor` calldata used for relaying the
/// stored batch info.
uint8 constant RELAYED_EXECUTOR_VERSION = 0;
/// @dev The version that is used for the `Executor` calldata used for relaying the
/// ZKSync OS stored batch info.
uint8 constant RELAYED_EXECUTOR_VERSION_ZKSYNC_OS = 1;

/// @title ZK chain Executor contract capable of processing events emitted in the ZK chain protocol.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ExecutorFacet is ZKChainBase, IExecutor {
    using UncheckedMath for uint256;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "ExecutorFacet";

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    /// @dev Timestamp - seconds since unix epoch.
    uint256 internal immutable COMMIT_TIMESTAMP_NOT_OLDER;

    constructor(uint256 _l1ChainId) {
        L1_CHAIN_ID = _l1ChainId;
        // Allow testnet operators to submit batches with older timestamps
        // compared to mainnet. This quality-of-life improvement is intended for
        // testnets, where outages may be resolved slower.
        if (L1_CHAIN_ID == MAINNET_CHAIN_ID) {
            COMMIT_TIMESTAMP_NOT_OLDER = MAINNET_COMMIT_TIMESTAMP_NOT_OLDER;
        } else {
            COMMIT_TIMESTAMP_NOT_OLDER = TESTNET_COMMIT_TIMESTAMP_NOT_OLDER;
        }
    }

    /// @dev Process one batch commit using the previous batch StoredBatchInfo
    /// @dev returns new batch StoredBatchInfo
    /// @notice Does not change storage
    function _commitOneBatch(
        StoredBatchInfo memory _previousBatch,
        CommitBatchInfo memory _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal returns (StoredBatchInfo memory storedBatchInfo) {
        // only commit next batch
        if (_newBatch.batchNumber != _previousBatch.batchNumber + 1) {
            revert BatchNumberMismatch(_previousBatch.batchNumber + 1, _newBatch.batchNumber);
        }

        // Check that batch contains all meta information for L2 logs.
        // Get the chained hash of priority transaction hashes.
        LogProcessingOutput memory logOutput = _processL2Logs(_newBatch, _expectedSystemContractUpgradeTxHash);

        L1DAValidatorOutput memory daOutput = IL1DAValidator(s.l1DAValidator).checkDA({
            _chainId: s.chainId,
            _batchNumber: uint256(_newBatch.batchNumber),
            _l2DAValidatorOutputHash: logOutput.l2DAValidatorOutputHash,
            _operatorDAInput: _newBatch.operatorDAInput,
            _maxBlobsSupported: TOTAL_BLOBS_IN_COMMITMENT
        });

        if (_previousBatch.batchHash != logOutput.previousBatchHash) {
            revert HashMismatch(logOutput.previousBatchHash, _previousBatch.batchHash);
        }
        // Check that the priority operation hash in the L2 logs is as expected
        if (logOutput.chainedPriorityTxsHash != _newBatch.priorityOperationsHash) {
            revert HashMismatch(logOutput.chainedPriorityTxsHash, _newBatch.priorityOperationsHash);
        }
        // Check that the number of processed priority operations is as expected
        if (logOutput.numberOfLayer1Txs != _newBatch.numberOfLayer1Txs) {
            revert ValueMismatch(logOutput.numberOfLayer1Txs, _newBatch.numberOfLayer1Txs);
        }
        _verifyAndResetBatchPrecommitment(_newBatch.batchNumber, logOutput.l2TxsStatusRollingHash);

        // Check the timestamp of the new batch
        _verifyBatchTimestamp(logOutput.packedBatchAndL2BlockTimestamp, _newBatch.timestamp, _previousBatch.timestamp);

        // Create batch commitment for the proof verification
        (bytes32 metadataHash, bytes32 auxiliaryOutputHash, bytes32 commitment) = _createBatchCommitment(
            _newBatch,
            daOutput.stateDiffHash,
            daOutput.blobsOpeningCommitments,
            daOutput.blobsLinearHashes
        );

        storedBatchInfo = StoredBatchInfo({
            batchNumber: _newBatch.batchNumber,
            batchHash: _newBatch.newStateRoot,
            indexRepeatedStorageChanges: _newBatch.indexRepeatedStorageChanges,
            numberOfLayer1Txs: _newBatch.numberOfLayer1Txs,
            priorityOperationsHash: _newBatch.priorityOperationsHash,
            l2LogsTreeRoot: logOutput.l2LogsTreeRoot,
            dependencyRootsRollingHash: logOutput.dependencyRootsRollingHash,
            timestamp: _newBatch.timestamp,
            commitment: commitment
        });

        if (L1_CHAIN_ID != block.chainid) {
            // If we are settling on top of Gateway, we always relay the data needed to construct
            // a proof for a new batch (and finalize it) even if the data for Gateway transactions has been fully lost.
            // This data includes:
            // - `StoredBatchInfo` that is needed to execute a block on top of the previous one.
            // But also, we need to ensure that the components of the commitment of the batch are available:
            // - passThroughDataHash (and its full preimage)
            // - metadataHash (only the hash)
            // - auxiliaryOutputHash (only the hash)
            // The source of the truth for the data from above can be found here:
            // https://github.com/matter-labs/zksync-protocol/blob/c80fa4ee94fd0f7f05f7aea364291abb8b4d7351/crates/zkevm_circuits/src/scheduler/mod.rs#L1356-L1369
            //
            // The full preimage of `passThroughDataHash` consists of the state root as well as the `indexRepeatedStorageChanges`. All
            // these values are already included as part of the `storedBatchInfo`, so we do not need to republish those.
            // slither-disable-next-line unused-return
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
                abi.encode(RELAYED_EXECUTOR_VERSION, storedBatchInfo, metadataHash, auxiliaryOutputHash)
            );
        }
    }

    function _commitOneBatchZKsyncOS(
        StoredBatchInfo memory _previousBatch,
        CommitBatchInfoZKsyncOS memory _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal returns (StoredBatchInfo memory storedBatchInfo) {
        // only commit next batch
        if (_newBatch.batchNumber != _previousBatch.batchNumber + 1) {
            revert BatchNumberMismatch(_previousBatch.batchNumber + 1, _newBatch.batchNumber);
        }

        // we can just ignore l1 da validator output with ZKsync OS:
        // - used state diffs hash correctness verified within state transition program
        // - blob commitments/linear hashes verification not supported, we use different way and custom DA validator for blobs with ZKsync OS
        L1DAValidatorOutput memory daOutput = IL1DAValidator(s.l1DAValidator).checkDA({
            _chainId: s.chainId,
            _batchNumber: uint256(_newBatch.batchNumber),
            _l2DAValidatorOutputHash: _newBatch.daCommitment,
            _operatorDAInput: _newBatch.operatorDAInput,
            _maxBlobsSupported: TOTAL_BLOBS_IN_COMMITMENT
        });
        // Theoretically, we can just ignore it, all the DA validators, except `RollupL1DAValidator`, always return a 0 array,
        // and `RollupL1DAValidator` will fail if we try to submit blobs with ZKsync OS, so it also returns zeroes here.
        // However, we are double-checking that the L1 DA validator doesn't rely on "EraVM like" blobs verification, just in case.
        if (
            daOutput.blobsLinearHashes.length != daOutput.blobsOpeningCommitments.length ||
            (daOutput.blobsLinearHashes.length != 0 && daOutput.blobsLinearHashes.length != TOTAL_BLOBS_IN_COMMITMENT)
        ) {
            revert InvalidNumberOfBlobs(
                TOTAL_BLOBS_IN_COMMITMENT,
                daOutput.blobsOpeningCommitments.length,
                daOutput.blobsLinearHashes.length
            );
        }
        uint256 blobsNumber = daOutput.blobsLinearHashes.length;
        for (uint256 i = 0; i < blobsNumber; ++i) {
            if (daOutput.blobsLinearHashes[i] != bytes32(0) || daOutput.blobsOpeningCommitments[i] != bytes32(0)) {
                revert NonZeroBlobToVerifyZKsyncOS(
                    i,
                    daOutput.blobsLinearHashes[i],
                    daOutput.blobsOpeningCommitments[i]
                );
            }
        }

        if (block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER > _newBatch.firstBlockTimestamp) {
            revert TimeNotReached(_newBatch.firstBlockTimestamp, block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER);
        }
        if (_newBatch.lastBlockTimestamp > block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA) {
            revert L2TimestampTooBig();
        }
        if (_newBatch.chainId != s.chainId) {
            revert IncorrectBatchChainId(_newBatch.chainId, s.chainId);
        }
        if (_newBatch.daCommitmentScheme != s.l2DACommitmentScheme) {
            revert MismatchL2DACommitmentScheme(uint256(_newBatch.daCommitmentScheme), uint256(s.l2DACommitmentScheme));
        }

        // The batch proof public input can be calculated as keccak256(state_commitment_before & state_commitment_after & batch_output_hash)
        // batch output hash commits to information about batch that needs to be opened on l1.
        // So below we are calculating batch output hash to later include it in the batch public input and thereby verify batch values correctness.
        bytes32 batchOutputHash = keccak256(
            abi.encodePacked(
                _newBatch.chainId,
                _newBatch.firstBlockTimestamp,
                _newBatch.lastBlockTimestamp,
                uint256(_newBatch.daCommitmentScheme),
                _newBatch.daCommitment,
                _newBatch.numberOfLayer1Txs,
                _newBatch.priorityOperationsHash,
                _newBatch.l2LogsTreeRoot,
                _expectedSystemContractUpgradeTxHash,
                _newBatch.dependencyRootsRollingHash
            )
        );

        // We are using same stored batch info structure as was used for Era VM state transition.
        // But we set some fields differently:
        // `batchHash` commitments now contains full commitment to the state and `indexRepeatedStorageChanges` not used(always set to 0)
        // `timestamp` is not used anymore(set to 0), for Era we used it to validate that committed batch timestamp is consistent with last stored,
        // but in ZKsync OS we are validating it within the state transition program
        storedBatchInfo = StoredBatchInfo({
            batchNumber: _newBatch.batchNumber,
            batchHash: _newBatch.newStateCommitment,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: _newBatch.numberOfLayer1Txs,
            priorityOperationsHash: _newBatch.priorityOperationsHash,
            l2LogsTreeRoot: _newBatch.l2LogsTreeRoot,
            dependencyRootsRollingHash: _newBatch.dependencyRootsRollingHash,
            timestamp: 0,
            commitment: batchOutputHash
        });

        if (L1_CHAIN_ID != block.chainid) {
            // If we are settling on top of Gateway, we always relay the data needed to construct
            // a proof for a new batch (and finalize it) even if the data for Gateway transactions has been fully lost.
            // For ZKsync OS this data includes only `StoredBatchInfo`: that is needed to commit and prove a batch on top of the previous one.
            // slither-disable-next-line unused-return
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
                abi.encode(RELAYED_EXECUTOR_VERSION_ZKSYNC_OS, storedBatchInfo)
            );
        }

        if (_newBatch.firstBlockNumber > _newBatch.lastBlockNumber) {
            revert InvalidBlockRange(_newBatch.batchNumber, _newBatch.firstBlockNumber, _newBatch.lastBlockNumber);
        }

        // Emitting the block range for a batch. This is needed for indexing purposes.
        // IMPORTANT:in this release this range is not trusted and provided by the operator while not being included to the proof.
        emit ReportCommittedBatchRangeZKsyncOS(
            _newBatch.batchNumber,
            _newBatch.firstBlockNumber,
            _newBatch.lastBlockNumber
        );
    }

    /// @notice Verifies that a stored precommitment for a given batch matches the expected rolling hash.
    /// @param _batchNumber The batch number whose precommitment is being verified.
    /// @param _expectedL2TxsStatusRollingHash The expected rolling hash of L2 transaction statuses for the batch.
    /// @dev Note, that precommitments are only supported for Era VM.
    function _verifyAndResetBatchPrecommitment(uint256 _batchNumber, bytes32 _expectedL2TxsStatusRollingHash) internal {
        bytes32 storedPrecommitment = s.precommitmentForTheLatestBatch;
        // The default value for the `storedPrecommitment` is expected to be `DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH`.
        // However, in case we did accidentally put 0 there, we want to handle this case as well.
        if (storedPrecommitment == bytes32(0)) {
            storedPrecommitment = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;
        }

        // We do not require the operator to always provide the precommitments as it is an optional feature.
        // However, if precommitments were provided, we do expect them to span over the entire batch
        if (
            storedPrecommitment != DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH &&
            storedPrecommitment != _expectedL2TxsStatusRollingHash
        ) {
            revert PrecommitmentMismatch(_batchNumber, _expectedL2TxsStatusRollingHash, storedPrecommitment);
        }

        // Resetting the stored precommitment.
        // Note, that the default value is not 0, but a non-zero value since rewriting a non-zero value
        // is cheaper than going from 0 and back within different transactions.
        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;
    }

    /// @notice checks that the timestamps of both the new batch and the new L2 block are correct.
    /// @param _packedBatchAndL2BlockTimestamp - packed batch and L2 block timestamp in a format of batchTimestamp * 2**128 + l2BatchTimestamp
    /// @param _expectedBatchTimestamp - expected batch timestamp
    /// @param _previousBatchTimestamp - the timestamp of the previous batch
    function _verifyBatchTimestamp(
        uint256 _packedBatchAndL2BlockTimestamp,
        uint256 _expectedBatchTimestamp,
        uint256 _previousBatchTimestamp
    ) internal view {
        // Check that the timestamp that came from the system context is expected
        uint256 batchTimestamp = _packedBatchAndL2BlockTimestamp >> 128;
        if (batchTimestamp != _expectedBatchTimestamp) {
            revert TimestampError();
        }

        // While the fact that _previousBatchTimestamp < batchTimestamp is already checked on L2,
        // we double check it here for clarity
        if (_previousBatchTimestamp >= batchTimestamp) {
            revert NonIncreasingTimestamp();
        }

        uint256 lastL2BlockTimestamp = _packedBatchAndL2BlockTimestamp & PACKED_L2_BLOCK_TIMESTAMP_MASK;
        // All L2 blocks have timestamps within the range of [batchTimestamp, lastL2BlockTimestamp].
        // So here we need to only double check that:
        // - The timestamp of the batch is not too small.
        // - The timestamp of the last L2 block is not too big.
        // New batch timestamp is too small
        if (block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER > batchTimestamp) {
            revert TimeNotReached(batchTimestamp, block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER);
        }
        // The last L2 block timestamp is too big
        if (lastL2BlockTimestamp > block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA) {
            revert L2TimestampTooBig();
        }
    }

    /// @dev Check that L2 logs are proper and batch contain all meta information for them
    /// @dev The logs processed here should line up such that only one log for each key from the
    ///      SystemLogKey enum in Constants.sol is processed per new batch.
    /// @dev Data returned from here will be used to form the batch commitment.
    function _processL2Logs(
        CommitBatchInfo memory _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal view returns (LogProcessingOutput memory logOutput) {
        // Copy L2 to L1 logs into memory.
        bytes memory emittedL2Logs = _newBatch.systemLogs;

        // Used as bitmap to set/check log processing happens exactly once.
        // See SystemLogKey enum in Constants.sol for ordering.
        uint256 processedLogs = 0;

        // linear traversal of the logs
        uint256 logsLength = emittedL2Logs.length;

        if (logsLength % L2_TO_L1_LOG_SERIALIZE_SIZE != 0) {
            revert InvalidSystemLogsLength();
        }

        for (uint256 i = 0; i < logsLength; i = i.uncheckedAdd(L2_TO_L1_LOG_SERIALIZE_SIZE)) {
            // Extract the values to be compared to/used such as the log sender, key, and value
            // slither-disable-next-line unused-return
            (address logSender, ) = UnsafeBytes.readAddress(emittedL2Logs, i + L2_LOG_ADDRESS_OFFSET);
            // slither-disable-next-line unused-return
            (uint256 logKey, ) = UnsafeBytes.readUint256(emittedL2Logs, i + L2_LOG_KEY_OFFSET);
            // slither-disable-next-line unused-return
            (bytes32 logValue, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + L2_LOG_VALUE_OFFSET);

            // Ensure that the log hasn't been processed already
            if (_checkBit(processedLogs, uint8(logKey))) {
                revert LogAlreadyProcessed(uint8(logKey));
            }
            processedLogs = _setBit(processedLogs, uint8(logKey));

            // Need to check that each log was sent by the correct address.
            if (logKey == uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY)) {
                _verifyLogSender(logSender, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, logKey);
                logOutput.l2LogsTreeRoot = logValue;
            } else if (logKey == uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)) {
                _verifyLogSender(logSender, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, logKey);
                logOutput.packedBatchAndL2BlockTimestamp = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.PREV_BATCH_HASH_KEY)) {
                _verifyLogSender(logSender, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, logKey);
                logOutput.previousBatchHash = logValue;
            } else if (logKey == uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                logOutput.chainedPriorityTxsHash = logValue;
            } else if (logKey == uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                logOutput.numberOfLayer1Txs = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY)) {
                _verifyLogSender(logSender, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, logKey);
                if (uint256(s.l2DACommitmentScheme) != uint256(logValue)) {
                    revert MismatchL2DACommitmentScheme(uint256(logValue), uint256(s.l2DACommitmentScheme));
                }
            } else if (logKey == uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY)) {
                _verifyLogSender(logSender, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, logKey);
                logOutput.l2DAValidatorOutputHash = logValue;
            } else if (logKey == uint256(SystemLogKey.L2_TXS_STATUS_ROLLING_HASH_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                logOutput.l2TxsStatusRollingHash = logValue;
            } else if (logKey == uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                if (_expectedSystemContractUpgradeTxHash != logValue) {
                    revert TxHashMismatch();
                }
            } else if (logKey == uint256(SystemLogKey.MESSAGE_ROOT_ROLLING_HASH_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                logOutput.dependencyRootsRollingHash = logValue;
            } else if (logKey == uint256(SystemLogKey.SETTLEMENT_LAYER_CHAIN_ID_KEY)) {
                _verifyLogSender(logSender, L2_BOOTLOADER_ADDRESS, logKey);
                uint256 settlementLayerChainId = uint256(logValue);
                require(settlementLayerChainId == block.chainid, SettlementLayerChainIdMismatch());
            } else if (logKey > MAX_LOG_KEY) {
                revert UnexpectedSystemLog(logKey);
            }
        }

        // We only require MAX_LOG_KEY - 1 logs to be checked, the MAX_LOG_KEY-th is if we are expecting a protocol upgrade
        uint256 exponent = _expectedSystemContractUpgradeTxHash == bytes32(0) ? MAX_LOG_KEY : MAX_LOG_KEY + 1;
        if (processedLogs != 2 ** exponent - 1) {
            revert MissingSystemLogs(2 ** exponent - 1, processedLogs);
        }
    }

    function _verifyLogSender(address _logSender, address _expected, uint256 _logKey) internal pure {
        if (_logSender != _expected) {
            revert InvalidLogSender(_logSender, _logKey);
        }
    }

    /// @inheritdoc IExecutor
    function precommitSharedBridge(
        address, // addr
        uint256 _batchNumber,
        bytes calldata _precommitData
    ) external nonReentrant onlyValidator onlySettlementLayer {
        uint256 expectedBatchNumber = s.totalBatchesCommitted + 1;
        if (_batchNumber != expectedBatchNumber) {
            revert InvalidBatchNumber(_batchNumber, expectedBatchNumber);
        }
        PrecommitInfo memory info = BatchDecoder.decodeAndCheckPrecommitData(_precommitData);
        if (info.packedTxsCommitments.length == 0) {
            revert EmptyPrecommitData(_batchNumber);
        }

        bytes32 currentPrecommitment = s.precommitmentForTheLatestBatch;
        // We have a placeholder non-zero value equal to `DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH`.
        // This is needed to ensure cheaper and more stable write costs.
        if (currentPrecommitment == DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH) {
            // The rolling hash calculation should start with 0.
            currentPrecommitment = 0;
        }

        bytes32 newPrecommitment = _calculatePrecommitmentRollingHash(currentPrecommitment, info.packedTxsCommitments);

        // We checked that the length of the precommitments is greater than zero,
        // so we know that this value will be non-zero as well.
        s.precommitmentForTheLatestBatch = newPrecommitment;

        emit BatchPrecommitmentSet(_batchNumber, info.untrustedLastL2BlockNumberHint, newPrecommitment);
    }

    /// @notice Calculates rolling hash of precommitments received from `_packedTxPrecommitments`.
    /// @param _currentPrecommitment The previous precommitment
    /// @param _packedTxPrecommitments The current precommitment
    /// @dev This function expects the number of new precommitments to be non-zero.
    function _calculatePrecommitmentRollingHash(
        bytes32 _currentPrecommitment,
        bytes memory _packedTxPrecommitments
    ) internal pure returns (bytes32 result) {
        unchecked {
            uint256 length = _packedTxPrecommitments.length;
            if (length % PACKED_L2_PRECOMMITMENT_LENGTH != 0) {
                revert InvalidPackedPrecommitmentLength(length);
            }

            // Caching constant(s) for use in assembly
            uint256 precommitmentLength = PACKED_L2_PRECOMMITMENT_LENGTH;
            /// @solidity memory-safe-assembly
            assembly {
                // Storing the current rolling hash in position 0. This way It will be more convenient
                // to recalculate it.
                mstore(0, _currentPrecommitment)

                // In assembly to access the elements of the array, we'll need to add 32 to the position
                // since the first 32 bytes store the length of the bytes array.
                let ptr := add(_packedTxPrecommitments, 32)
                let ptrTo := add(ptr, length)

                for {

                } lt(ptr, ptrTo) {
                    ptr := add(ptr, precommitmentLength)
                } {
                    let txPrecommitment := keccak256(ptr, precommitmentLength)

                    // Storing the precommitment for the transaction and recalculating the rolling hash
                    mstore(32, txPrecommitment)
                    result := keccak256(0, 64)
                    mstore(0, result)
                }
            }
        }
    }

    /// @dev Checks that the batch hash is correct and matches the expected hash.
    /// @param _lastCommittedBatchData The last committed batch.
    /// @param _batchNumber The batch number to check.
    /// @param _checkLegacy Whether to check the legacy hash.
    function _checkBatchHashMismatch(
        StoredBatchInfo memory _lastCommittedBatchData,
        uint256 _batchNumber,
        bool _checkLegacy
    ) internal view {
        bytes32 cachedStoredBatchHashes = s.storedBatchHashes[_batchNumber];
        if (
            cachedStoredBatchHashes != _hashStoredBatchInfo(_lastCommittedBatchData) &&
            (!_checkLegacy || cachedStoredBatchHashes != _hashLegacyStoredBatchInfo(_lastCommittedBatchData))
        ) {
            // incorrect previous batch data
            revert BatchHashMismatch(cachedStoredBatchHashes, _hashStoredBatchInfo(_lastCommittedBatchData));
        }
    }

    function _commitBatchesSharedBridgeEra(
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) internal {
        (StoredBatchInfo memory lastCommittedBatchData, CommitBatchInfo[] memory newBatchesData) = BatchDecoder
            .decodeAndCheckCommitData(_commitData, _processFrom, _processTo);
        // With the new changes for EIP-4844, namely the restriction on number of blobs per block, we only allow for a single batch to be committed at a time.
        // Note: Don't need to check that `_processFrom` == `_processTo` because there is only one batch,
        // and so the range checked in the `decodeAndCheckCommitData` is enough.
        if (newBatchesData.length != 1) {
            revert CanOnlyProcessOneBatch();
        }
        // Check that we commit batches after last committed batch
        _checkBatchHashMismatch(lastCommittedBatchData, s.totalBatchesCommitted, true);

        bytes32 systemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        // Upgrades are rarely done so we optimize a case with no active system contracts upgrade.
        if (systemContractsUpgradeTxHash == bytes32(0) || s.l2SystemContractsUpgradeBatchNumber != 0) {
            _commitBatchesEra(lastCommittedBatchData, newBatchesData, bytes32(0));
        } else {
            // The system contract upgrade is designed to be executed atomically with the new bootloader, a default account,
            // ZKP verifier, and other system parameters. Hence, we ensure that the upgrade transaction is
            // carried out within the first batch committed after the upgrade.

            // While the logic of the contract ensures that the s.l2SystemContractsUpgradeBatchNumber is 0 when this branch is entered,
            // this check is added just in case. Since it is a hot read, it does not incur noticeable gas cost.
            if (s.l2SystemContractsUpgradeBatchNumber != 0) {
                revert UpgradeBatchNumberIsNotZero();
            }

            // Save the batch number where the upgrade transaction was executed.
            s.l2SystemContractsUpgradeBatchNumber = newBatchesData[0].batchNumber;

            _commitBatchesEra(lastCommittedBatchData, newBatchesData, systemContractsUpgradeTxHash);
        }

        s.totalBatchesCommitted = s.totalBatchesCommitted + newBatchesData.length;
    }

    function _commitBatchesSharedBridgeZKsyncOS(
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) internal {
        (StoredBatchInfo memory lastCommittedBatchData, CommitBatchInfoZKsyncOS[] memory newBatchesData) = BatchDecoder
            .decodeAndCheckCommitDataZKsyncOS(_commitData, _processFrom, _processTo);
        // With the new changes for EIP-4844, namely the restriction on number of blobs per block, we only allow for a single batch to be committed at a time.
        // Note: Don't need to check that `_processFrom` == `_processTo` because there is only one batch,
        // and so the range checked in the `decodeAndCheckCommitData` is enough.
        if (newBatchesData.length != 1) {
            revert CanOnlyProcessOneBatch();
        }
        // Check that we commit batches after last committed batch
        _checkBatchHashMismatch(lastCommittedBatchData, s.totalBatchesCommitted, false);

        bytes32 systemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        bool processSystemUpgradeTx = systemContractsUpgradeTxHash != bytes32(0) &&
            s.l2SystemContractsUpgradeBatchNumber == 0;
        _commitBatchesZKsyncOS(lastCommittedBatchData, newBatchesData, processSystemUpgradeTx);

        s.totalBatchesCommitted = s.totalBatchesCommitted + newBatchesData.length;
    }

    /// @inheritdoc IExecutor
    function commitBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) external nonReentrant onlyValidator onlySettlementLayer {
        // check that we have the right protocol version
        // three comments:
        // 1. A chain has to keep their protocol version up to date, as processing a block requires the latest or previous protocol version
        // to solve this we will need to add the feature to create batches with only the protocol upgrade tx, without any other txs.
        // 2. A chain might become out of sync if it launches while we are in the middle of a protocol upgrade. This would mean they cannot process their genesis upgrade
        // as their protocolversion would be outdated, and they also cannot process the protocol upgrade tx as they have a pending upgrade.
        // 3. The protocol upgrade is increased in the BaseZkSyncUpgrade, in the executor only the systemContractsUpgradeTxHash is checked
        if (!IChainTypeManager(s.chainTypeManager).protocolVersionIsActive(s.protocolVersion)) {
            revert InvalidProtocolVersion();
        }
        if (s.zksyncOS) {
            _commitBatchesSharedBridgeZKsyncOS(_processFrom, _processTo, _commitData);
        } else {
            _commitBatchesSharedBridgeEra(_processFrom, _processTo, _commitData);
        }
    }

    /// @dev Commits new batches, optionally handling a system contracts upgrade transaction.
    /// @param _lastCommittedBatchData The data of the last committed batch.
    /// @param _newBatchesData An array of batch data that needs to be committed.
    /// @param _systemContractUpgradeTxHash The transaction hash of the system contract upgrade (bytes32(0) if none).
    function _commitBatchesEra(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] memory _newBatchesData,
        bytes32 _systemContractUpgradeTxHash
    ) internal {
        // We disable this check because calldata array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _newBatchesData.length; i = i.uncheckedInc()) {
            _lastCommittedBatchData = _commitOneBatch(
                _lastCommittedBatchData,
                _newBatchesData[i],
                _systemContractUpgradeTxHash
            );

            s.storedBatchHashes[_lastCommittedBatchData.batchNumber] = _hashStoredBatchInfo(_lastCommittedBatchData);
            emit BlockCommit(
                _lastCommittedBatchData.batchNumber,
                _lastCommittedBatchData.batchHash,
                _lastCommittedBatchData.commitment
            );

            if (i == 0) {
                // The upgrade transaction must only be included in the first batch.
                _systemContractUpgradeTxHash = bytes32(0);
            }
        }
    }

    function _commitBatchesZKsyncOS(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfoZKsyncOS[] memory _newBatchesData,
        bool _processSystemUpgradeTx
    ) internal {
        bytes32 upgradeTxHash;
        if (_processSystemUpgradeTx) {
            // While the logic of the contract ensures that the s.l2SystemContractsUpgradeBatchNumber is 0 when _processSystemUpgradeTx is true,
            // this check is added just in case. Since it is a hot read, it does not incur noticeable gas cost.
            if (s.l2SystemContractsUpgradeBatchNumber != 0) {
                revert UpgradeBatchNumberIsNotZero();
            }

            // Save the batch number where the upgrade transaction was executed.
            s.l2SystemContractsUpgradeBatchNumber = _newBatchesData[0].batchNumber;
            upgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        }

        // We disable this check because calldata array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _newBatchesData.length; i = i.uncheckedInc()) {
            _lastCommittedBatchData = _commitOneBatchZKsyncOS(
                _lastCommittedBatchData,
                _newBatchesData[i],
                upgradeTxHash
            );

            s.storedBatchHashes[_lastCommittedBatchData.batchNumber] = _hashStoredBatchInfo(_lastCommittedBatchData);
            emit BlockCommit(
                _lastCommittedBatchData.batchNumber,
                _lastCommittedBatchData.batchHash,
                _lastCommittedBatchData.commitment
            );

            // reset upgradeTxHash after the first batch
            if (i == 0) {
                upgradeTxHash = bytes32(0);
            }
        }
    }

    function _rollingHash(bytes32[] memory _hashes) internal pure returns (bytes32) {
        bytes32 hash = EMPTY_STRING_KECCAK;
        uint256 nHashes = _hashes.length;
        for (uint256 i = 0; i < nHashes; i = i.uncheckedInc()) {
            hash = keccak256(abi.encode(hash, _hashes[i]));
        }
        return hash;
    }

    /// @dev Checks that the data of the batch is correct and can be executed
    /// @dev Verifies that batch number, batch hash and priority operations hash are correct
    function _checkBatchData(
        StoredBatchInfo memory _storedBatch,
        uint256 _executedBatchIdx,
        bytes32 _priorityOperationsHash,
        bytes32 _dependencyRootsRollingHash
    ) internal view {
        uint256 currentBatchNumber = _storedBatch.batchNumber;
        if (currentBatchNumber != s.totalBatchesExecuted + _executedBatchIdx + 1) {
            revert NonSequentialBatch();
        }
        _checkBatchHashMismatch(_storedBatch, currentBatchNumber, false);
        if (_priorityOperationsHash != _storedBatch.priorityOperationsHash) {
            revert PriorityOperationsRollingHashMismatch();
        }
        if (_dependencyRootsRollingHash != _storedBatch.dependencyRootsRollingHash) {
            revert DependencyRootsRollingHashMismatch(
                _storedBatch.dependencyRootsRollingHash,
                _dependencyRootsRollingHash
            );
        }
    }

    /// @notice Executes one batch
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes batch
    /// @dev _executedBatchIdx is an index in the array of the batches that we want to execute together
    function _executeOneBatch(
        StoredBatchInfo memory _storedBatch,
        PriorityOpsBatchInfo memory _priorityOpsData,
        InteropRoot[] memory _dependencyRoots,
        uint256 _executedBatchIdx
    ) internal {
        if (_priorityOpsData.itemHashes.length != _storedBatch.numberOfLayer1Txs) {
            revert MismatchNumberOfLayer1Txs(_storedBatch.numberOfLayer1Txs, _priorityOpsData.itemHashes.length);
        }
        bytes32 priorityOperationsHash = _rollingHash(_priorityOpsData.itemHashes);
        bytes32 dependencyRootsRollingHash = _verifyDependencyInteropRoots(_dependencyRoots);
        _checkBatchData(_storedBatch, _executedBatchIdx, priorityOperationsHash, dependencyRootsRollingHash);
        s.priorityTree.processBatch(_priorityOpsData);

        uint256 currentBatchNumber = _storedBatch.batchNumber;

        // Save root hash of L2 -> L1 logs tree
        s.l2LogsRootHashes[currentBatchNumber] = _storedBatch.l2LogsTreeRoot;
    }

    /// @notice Verifies the dependency message roots that the chain relied on.
    function _verifyDependencyInteropRoots(
        InteropRoot[] memory _dependencyRoots
    ) internal view returns (bytes32 dependencyRootsRollingHash) {
        uint256 length = _dependencyRoots.length;
        IMessageRoot messageRootContract = IBridgehubBase(s.bridgehub).messageRoot();

        for (uint256 i = 0; i < length; i = i.uncheckedInc()) {
            InteropRoot memory interopRoot = _dependencyRoots[i];
            bytes32 correctRootHash;
            if (interopRoot.chainId == block.chainid) {
                // For the same chain we verify using the MessageRoot contract. Note, that in this
                // release, import and export only happens on GW, so this is the only case we have to cover.
                correctRootHash = messageRootContract.historicalRoot(uint256(interopRoot.blockOrBatchNumber));
            } else {
                revert CommitBasedInteropNotSupported();
            }
            if (correctRootHash == bytes32(0)) {
                revert MessageRootIsZero();
            }
            if (interopRoot.sides.length != 1 || interopRoot.sides[0] != correctRootHash) {
                revert InvalidMessageRoot(correctRootHash, interopRoot.sides[0]);
            }
            dependencyRootsRollingHash = keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(
                    dependencyRootsRollingHash,
                    interopRoot.chainId,
                    interopRoot.blockOrBatchNumber,
                    interopRoot.sides
                )
            );
        }
    }

    /// @notice Appends the batch message root to the global message.
    /// @param _batchNumber The number of the batch
    /// @param _messageRoot The root of the merkle tree of the messages to L1.
    /// @dev We only call this function on L1.
    function _appendMessageRoot(uint256 _batchNumber, bytes32 _messageRoot) internal {
        // Once the batch is executed, we include its message to the message root.
        IMessageRoot messageRootContract = IBridgehubBase(s.bridgehub).messageRoot();
        messageRootContract.addChainBatchRoot(s.chainId, _batchNumber, _messageRoot);
    }

    /// @inheritdoc IExecutor
    function executeBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external nonReentrant onlyValidator onlySettlementLayer {
        (
            StoredBatchInfo[] memory batchesData,
            PriorityOpsBatchInfo[] memory priorityOpsData,
            InteropRoot[][] memory dependencyRoots,
            L2Log[][] memory logs,
            bytes[][] memory messages,
            bytes32[] memory messageRoots
        ) = BatchDecoder.decodeAndCheckExecuteData(_executeData, _processFrom, _processTo);
        uint256 nBatches = batchesData.length;
        if (batchesData.length != priorityOpsData.length) {
            revert InvalidBatchesDataLength(batchesData.length, priorityOpsData.length);
        }
        if (block.chainid == L1_CHAIN_ID) {
            require(logs.length == 0, InvalidBatchesDataLength(0, logs.length));
            require(messages.length == 0, InvalidBatchesDataLength(0, messages.length));
        } else {
            require(batchesData.length == logs.length, InvalidBatchesDataLength(batchesData.length, logs.length));
            require(
                batchesData.length == messages.length,
                InvalidBatchesDataLength(batchesData.length, messages.length)
            );
        }

        // Interop is only allowed on GW currently, so we go through the Asset Tracker when on Gateway.
        // When on L1, we append directly to the Message Root, though interop is not allowed there, it is only used for
        // message verification.
        if (block.chainid != L1_CHAIN_ID) {
            uint256 messagesLength = messages.length;
            for (uint256 i = 0; i < messagesLength; i = i.uncheckedInc()) {
                ProcessLogsInput memory processLogsInput = ProcessLogsInput({
                    logs: logs[i],
                    messages: messages[i],
                    chainId: s.chainId,
                    batchNumber: batchesData[i].batchNumber,
                    chainBatchRoot: batchesData[i].l2LogsTreeRoot,
                    messageRoot: messageRoots[i]
                });
                GW_ASSET_TRACKER.processLogsAndMessages(processLogsInput);
            }
        } else {
            uint256 batchesDataLength = batchesData.length;
            for (uint256 i = 0; i < batchesDataLength; i = i.uncheckedInc()) {
                _appendMessageRoot(batchesData[i].batchNumber, batchesData[i].l2LogsTreeRoot);
            }
        }

        for (uint256 i = 0; i < nBatches; i = i.uncheckedInc()) {
            _executeOneBatch(batchesData[i], priorityOpsData[i], dependencyRoots[i], i);
            emit BlockExecution(batchesData[i].batchNumber, batchesData[i].batchHash, batchesData[i].commitment);
        }

        uint256 newTotalBatchesExecuted = s.totalBatchesExecuted + nBatches;
        s.totalBatchesExecuted = newTotalBatchesExecuted;
        if (newTotalBatchesExecuted > s.totalBatchesVerified) {
            revert CantExecuteUnprovenBatches();
        }

        uint256 batchWhenUpgradeHappened = s.l2SystemContractsUpgradeBatchNumber;
        if (batchWhenUpgradeHappened != 0 && batchWhenUpgradeHappened <= newTotalBatchesExecuted) {
            delete s.l2SystemContractsUpgradeTxHash;
            delete s.l2SystemContractsUpgradeBatchNumber;
        }
    }

    /// @inheritdoc IExecutor
    function proveBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _proofData
    ) external nonReentrant onlyValidator onlySettlementLayer {
        (
            StoredBatchInfo memory prevBatch,
            StoredBatchInfo[] memory committedBatches,
            uint256[] memory proof
        ) = BatchDecoder.decodeAndCheckProofData(_proofData, _processBatchFrom, _processBatchTo);

        // Save the variables into the stack to save gas on reading them later
        uint256 currentTotalBatchesVerified = s.totalBatchesVerified;
        uint256 committedBatchesLength = committedBatches.length;

        // Initialize the array, that will be used as public input to the ZKP
        uint256[] memory proofPublicInput = new uint256[](committedBatchesLength);

        // Check that the batch passed by the validator is indeed the first unverified batch
        _checkBatchHashMismatch(prevBatch, currentTotalBatchesVerified, true);

        bytes32 prevBatchCommitment = prevBatch.commitment;
        bytes32 prevBatchStateCommitment = prevBatch.batchHash;
        for (uint256 i = 0; i < committedBatchesLength; i = i.uncheckedInc()) {
            currentTotalBatchesVerified = currentTotalBatchesVerified.uncheckedInc();
            _checkBatchHashMismatch(committedBatches[i], currentTotalBatchesVerified, false);

            bytes32 currentBatchCommitment = committedBatches[i].commitment;
            bytes32 currentBatchStateCommitment = committedBatches[i].batchHash;
            if (s.zksyncOS) {
                proofPublicInput[i] = _getBatchProofPublicInputZKsyncOS(
                    prevBatchStateCommitment,
                    currentBatchStateCommitment,
                    currentBatchCommitment
                );
            } else {
                proofPublicInput[i] = _getBatchProofPublicInput(prevBatchCommitment, currentBatchCommitment);
            }

            prevBatchCommitment = currentBatchCommitment;
            prevBatchStateCommitment = currentBatchStateCommitment;
        }
        if (currentTotalBatchesVerified > s.totalBatchesCommitted) {
            revert VerifiedBatchesExceedsCommittedBatches();
        }

        _verifyProof(proofPublicInput, proof);

        emit BlocksVerification(s.totalBatchesVerified, currentTotalBatchesVerified);
        s.totalBatchesVerified = currentTotalBatchesVerified;
    }

    function _verifyProof(uint256[] memory proofPublicInput, uint256[] memory _proof) internal view {
        // We only allow processing of 1 batch proof at a time on Era Chains.
        // We allow processing multiple proofs at once on ZKsync OS Chains.
        if (!s.zksyncOS && proofPublicInput.length != 1) {
            revert CanOnlyProcessOneBatch();
        }

        bool successVerifyProof = s.verifier.verify(proofPublicInput, _proof);
        if (!successVerifyProof) {
            revert InvalidProof();
        }
    }

    /// @dev Gets zk proof public input for ZKSync OS
    function _getBatchProofPublicInputZKsyncOS(
        bytes32 _prevBatchStateCommitment,
        bytes32 _currentBatchStateCommitment,
        bytes32 _currentBatchCommitment
    ) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(_prevBatchStateCommitment, _currentBatchStateCommitment, _currentBatchCommitment)
                )
            ) >> PUBLIC_INPUT_SHIFT;
    }

    /// @dev Gets zk proof public input for Era
    function _getBatchProofPublicInput(
        bytes32 _prevBatchCommitment,
        bytes32 _currentBatchCommitment
    ) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(_prevBatchCommitment, _currentBatchCommitment))) >> PUBLIC_INPUT_SHIFT;
    }

    /// @inheritdoc IExecutor
    function revertBatchesSharedBridge(
        address,
        uint256 _newLastBatch
    ) external nonReentrant onlyValidatorOrChainTypeManager {
        _revertBatches(_newLastBatch);
    }

    function _revertBatches(uint256 _newLastBatch) internal onlySettlementLayer {
        if (s.totalBatchesCommitted < _newLastBatch) {
            revert RevertedBatchNotAfterNewLastBatch();
        }
        if (_newLastBatch < s.totalBatchesExecuted) {
            revert CantRevertExecutedBatch();
        }

        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;

        if (_newLastBatch < s.totalBatchesVerified) {
            s.totalBatchesVerified = _newLastBatch;
        }
        s.totalBatchesCommitted = _newLastBatch;

        // Reset the batch number of the executed system contracts upgrade transaction if the batch
        // where the system contracts upgrade was committed is among the reverted batches.
        if (s.l2SystemContractsUpgradeBatchNumber > _newLastBatch) {
            delete s.l2SystemContractsUpgradeBatchNumber;
        }

        emit BlocksRevert(s.totalBatchesCommitted, s.totalBatchesVerified, s.totalBatchesExecuted);
    }

    /// @dev Creates batch commitment from its data
    function _createBatchCommitment(
        CommitBatchInfo memory _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal view returns (bytes32 metadataHash, bytes32 auxiliaryOutputHash, bytes32 commitment) {
        bytes32 passThroughDataHash = keccak256(_batchPassThroughData(_newBatchData));
        metadataHash = keccak256(_batchMetaParameters());
        auxiliaryOutputHash = keccak256(
            _batchAuxiliaryOutput(_newBatchData, _stateDiffHash, _blobCommitments, _blobHashes)
        );

        commitment = keccak256(abi.encode(passThroughDataHash, metadataHash, auxiliaryOutputHash));
    }

    function _batchPassThroughData(CommitBatchInfo memory _batch) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                // solhint-disable-next-line func-named-parameters
                _batch.indexRepeatedStorageChanges,
                _batch.newStateRoot,
                uint64(0), // index repeated storage changes in zkPorter
                bytes32(0) // zkPorter batch hash
            );
    }

    function _batchMetaParameters() internal view returns (bytes memory) {
        return
            abi.encodePacked(
                s.zkPorterIsAvailable,
                s.l2BootloaderBytecodeHash,
                s.l2DefaultAccountBytecodeHash,
                s.l2EvmEmulatorBytecodeHash
            );
    }

    function _batchAuxiliaryOutput(
        CommitBatchInfo memory _batch,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes memory) {
        if (_batch.systemLogs.length > MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES) {
            revert SystemLogsSizeTooBig();
        }

        bytes32 l2ToL1LogsHash = keccak256(_batch.systemLogs);

        return
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(
                l2ToL1LogsHash,
                _stateDiffHash,
                _batch.bootloaderHeapInitialContentsHash,
                _batch.eventsQueueStateHash,
                _encodeBlobAuxiliaryOutput(_blobCommitments, _blobHashes)
            );
    }

    /// @dev Encodes the commitment to blobs to be used in the auxiliary output of the batch commitment
    /// @param _blobCommitments - the commitments to the blobs
    /// @param _blobHashes - the hashes of the blobs
    /// @param blobAuxOutputWords - The circuit commitment to the blobs split into 32-byte words
    function _encodeBlobAuxiliaryOutput(
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes32[] memory blobAuxOutputWords) {
        // These invariants should be checked by the caller of this function, but we double check
        // just in case.
        if (_blobCommitments.length != TOTAL_BLOBS_IN_COMMITMENT || _blobHashes.length != TOTAL_BLOBS_IN_COMMITMENT) {
            revert InvalidNumberOfBlobs(TOTAL_BLOBS_IN_COMMITMENT, _blobCommitments.length, _blobHashes.length);
        }

        // for each blob we have:
        // linear hash (hash of preimage from system logs) and
        // output hash of blob commitments: keccak(versioned hash || opening point || evaluation value)
        // These values will all be bytes32(0) when we submit pubdata via calldata instead of blobs.
        //
        // For now, only up to 6 blobs are supported by the contract, while 16 are required by the circuits.
        // All the unfilled blobs will have their commitment as 0, including the case when we use only 1 blob.

        blobAuxOutputWords = new bytes32[](2 * TOTAL_BLOBS_IN_COMMITMENT);

        for (uint256 i = 0; i < TOTAL_BLOBS_IN_COMMITMENT; ++i) {
            blobAuxOutputWords[i * 2] = _blobHashes[i];
            blobAuxOutputWords[i * 2 + 1] = _blobCommitments[i];
        }
    }

    /// @notice Returns the keccak hash of the ABI-encoded StoredBatchInfo
    function _hashStoredBatchInfo(StoredBatchInfo memory _storedBatchInfo) internal pure returns (bytes32) {
        return keccak256(abi.encode(_storedBatchInfo));
    }

    /// @notice Returns the keccak hash of the ABI-encoded Legacy StoredBatchInfo
    function _hashLegacyStoredBatchInfo(StoredBatchInfo memory _storedBatchInfo) internal pure returns (bytes32) {
        LegacyStoredBatchInfo memory legacyStoredBatchInfo = LegacyStoredBatchInfo({
            batchNumber: _storedBatchInfo.batchNumber,
            batchHash: _storedBatchInfo.batchHash,
            indexRepeatedStorageChanges: _storedBatchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: _storedBatchInfo.numberOfLayer1Txs,
            priorityOperationsHash: _storedBatchInfo.priorityOperationsHash,
            l2LogsTreeRoot: _storedBatchInfo.l2LogsTreeRoot,
            timestamp: _storedBatchInfo.timestamp,
            commitment: _storedBatchInfo.commitment
        });
        return keccak256(abi.encode(legacyStoredBatchInfo));
    }

    /// @notice Returns true if the bit at index {_index} is 1
    function _checkBit(uint256 _bitMap, uint8 _index) internal pure returns (bool) {
        return (_bitMap & (1 << _index)) > 0;
    }

    /// @notice Sets the given bit in {_num} at index {_index} to 1.
    function _setBit(uint256 _bitMap, uint8 _index) internal pure returns (uint256) {
        return _bitMap | (1 << _index);
    }
}
