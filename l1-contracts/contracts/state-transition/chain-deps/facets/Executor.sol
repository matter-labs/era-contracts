// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBase} from "./ZKChainBase.sol";
import {IBridgehub} from "../../../bridgehub/IBridgehub.sol";
import {IMessageRoot} from "../../../bridgehub/IMessageRoot.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, COMMIT_TIMESTAMP_APPROXIMATION_DELTA, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE, MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, PACKED_L2_BLOCK_TIMESTAMP_MASK, PUBLIC_INPUT_SHIFT} from "../../../common/Config.sol";
import {IExecutor, L2_LOG_ADDRESS_OFFSET, L2_LOG_KEY_OFFSET, L2_LOG_VALUE_OFFSET, SystemLogKey, LogProcessingOutput, TOTAL_BLOBS_IN_COMMITMENT} from "../../chain-interfaces/IExecutor.sol";
import {PriorityQueue, PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {BatchDecoder} from "../../libraries/BatchDecoder.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../../common/libraries/UnsafeBytes.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../../../common/L2ContractAddresses.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {PriorityTree, PriorityOpsBatchInfo} from "../../libraries/PriorityTree.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "../../chain-interfaces/IL1DAValidator.sol";
import {InvalidSystemLogsLength, MissingSystemLogs, BatchNumberMismatch, TimeNotReached, ValueMismatch, HashMismatch, NonIncreasingTimestamp, TimestampError, InvalidLogSender, TxHashMismatch, UnexpectedSystemLog, LogAlreadyProcessed, InvalidProtocolVersion, CanOnlyProcessOneBatch, BatchHashMismatch, UpgradeBatchNumberIsNotZero, NonSequentialBatch, CantExecuteUnprovenBatches, SystemLogsSizeTooBig, InvalidNumberOfBlobs, VerifiedBatchesExceedsCommittedBatches, InvalidProof, RevertedBatchNotAfterNewLastBatch, CantRevertExecutedBatch, L2TimestampTooBig, PriorityOperationsRollingHashMismatch} from "../../../common/L1ContractErrors.sol";
import {InvalidBatchesDataLength, MismatchL2DAValidator, MismatchNumberOfLayer1Txs, PriorityOpsDataLeftPathLengthIsNotZero, PriorityOpsDataRightPathLengthIsNotZero, PriorityOpsDataItemHashesLengthIsNotZero} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @dev The version that is used for the `Executor` calldata used for relaying the
/// stored batch info.
uint8 constant RELAYED_EXECUTOR_VERSION = 0;

/// @title ZK chain Executor contract capable of processing events emitted in the ZK chain protocol.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ExecutorFacet is ZKChainBase, IExecutor {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    string public constant override getName = "ExecutorFacet";

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    constructor(uint256 _l1ChainId) {
        L1_CHAIN_ID = _l1ChainId;
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
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR.sendToL1(
                abi.encode(RELAYED_EXECUTOR_VERSION, storedBatchInfo, metadataHash, auxiliaryOutputHash)
            );
        }
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
                if (logSender != address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR)) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.l2LogsTreeRoot = logValue;
            } else if (logKey == uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)) {
                if (logSender != L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.packedBatchAndL2BlockTimestamp = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.PREV_BATCH_HASH_KEY)) {
                if (logSender != L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.previousBatchHash = logValue;
            } else if (logKey == uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)) {
                if (logSender != L2_BOOTLOADER_ADDRESS) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.chainedPriorityTxsHash = logValue;
            } else if (logKey == uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)) {
                if (logSender != L2_BOOTLOADER_ADDRESS) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.numberOfLayer1Txs = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.USED_L2_DA_VALIDATOR_ADDRESS_KEY)) {
                if (logSender != address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR)) {
                    revert InvalidLogSender(logSender, logKey);
                }
                if (s.l2DAValidator != address(uint160(uint256(logValue)))) {
                    revert MismatchL2DAValidator();
                }
            } else if (logKey == uint256(SystemLogKey.L2_DA_VALIDATOR_OUTPUT_HASH_KEY)) {
                if (logSender != address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR)) {
                    revert InvalidLogSender(logSender, logKey);
                }
                logOutput.l2DAValidatorOutputHash = logValue;
            } else if (logKey == uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY)) {
                if (logSender != L2_BOOTLOADER_ADDRESS) {
                    revert InvalidLogSender(logSender, logKey);
                }
                if (_expectedSystemContractUpgradeTxHash != logValue) {
                    revert TxHashMismatch();
                }
            } else if (logKey > uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY)) {
                revert UnexpectedSystemLog(logKey);
            }
        }

        // We only require 7 logs to be checked, the 8th is if we are expecting a protocol upgrade
        // Without the protocol upgrade we expect 7 logs: 2^7 - 1 = 127
        // With the protocol upgrade we expect 8 logs: 2^8 - 1 = 255
        if (_expectedSystemContractUpgradeTxHash == bytes32(0)) {
            if (processedLogs != 127) {
                revert MissingSystemLogs(127, processedLogs);
            }
        } else if (processedLogs != 255) {
            revert MissingSystemLogs(255, processedLogs);
        }
    }

    /// @inheritdoc IExecutor
    function commitBatchesSharedBridge(
        uint256, // _chainId
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
        (StoredBatchInfo memory lastCommittedBatchData, CommitBatchInfo[] memory newBatchesData) = BatchDecoder
            .decodeAndCheckCommitData(_commitData, _processFrom, _processTo);
        // With the new changes for EIP-4844, namely the restriction on number of blobs per block, we only allow for a single batch to be committed at a time.
        // Note: Don't need to check that `_processFrom` == `_processTo` because there is only one batch,
        // and so the range checked in the `decodeAndCheckCommitData` is enough.
        if (newBatchesData.length != 1) {
            revert CanOnlyProcessOneBatch();
        }
        // Check that we commit batches after last committed batch
        if (s.storedBatchHashes[s.totalBatchesCommitted] != _hashStoredBatchInfo(lastCommittedBatchData)) {
            // incorrect previous batch data
            revert BatchHashMismatch(
                s.storedBatchHashes[s.totalBatchesCommitted],
                _hashStoredBatchInfo(lastCommittedBatchData)
            );
        }

        bytes32 systemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        // Upgrades are rarely done so we optimize a case with no active system contracts upgrade.
        if (systemContractsUpgradeTxHash == bytes32(0) || s.l2SystemContractsUpgradeBatchNumber != 0) {
            _commitBatchesWithoutSystemContractsUpgrade(lastCommittedBatchData, newBatchesData);
        } else {
            _commitBatchesWithSystemContractsUpgrade(
                lastCommittedBatchData,
                newBatchesData,
                systemContractsUpgradeTxHash
            );
        }

        s.totalBatchesCommitted = s.totalBatchesCommitted + newBatchesData.length;
    }

    /// @dev Commits new batches without any system contracts upgrade.
    /// @param _lastCommittedBatchData The data of the last committed batch.
    /// @param _newBatchesData An array of batch data that needs to be committed.
    function _commitBatchesWithoutSystemContractsUpgrade(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] memory _newBatchesData
    ) internal {
        // We disable this check because calldata array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _newBatchesData.length; i = i.uncheckedInc()) {
            _lastCommittedBatchData = _commitOneBatch(_lastCommittedBatchData, _newBatchesData[i], bytes32(0));

            s.storedBatchHashes[_lastCommittedBatchData.batchNumber] = _hashStoredBatchInfo(_lastCommittedBatchData);
            emit BlockCommit(
                _lastCommittedBatchData.batchNumber,
                _lastCommittedBatchData.batchHash,
                _lastCommittedBatchData.commitment
            );
        }
    }

    /// @dev Commits new batches with a system contracts upgrade transaction.
    /// @param _lastCommittedBatchData The data of the last committed batch.
    /// @param _newBatchesData An array of batch data that needs to be committed.
    /// @param _systemContractUpgradeTxHash The transaction hash of the system contract upgrade.
    function _commitBatchesWithSystemContractsUpgrade(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] memory _newBatchesData,
        bytes32 _systemContractUpgradeTxHash
    ) internal {
        // The system contract upgrade is designed to be executed atomically with the new bootloader, a default account,
        // ZKP verifier, and other system parameters. Hence, we ensure that the upgrade transaction is
        // carried out within the first batch committed after the upgrade.

        // While the logic of the contract ensures that the s.l2SystemContractsUpgradeBatchNumber is 0 when this function is called,
        // this check is added just in case. Since it is a hot read, it does not incur noticeable gas cost.
        if (s.l2SystemContractsUpgradeBatchNumber != 0) {
            revert UpgradeBatchNumberIsNotZero();
        }

        // Save the batch number where the upgrade transaction was executed.
        s.l2SystemContractsUpgradeBatchNumber = _newBatchesData[0].batchNumber;

        // We disable this check because calldata array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _newBatchesData.length; i = i.uncheckedInc()) {
            // The upgrade transaction must only be included in the first batch.
            bytes32 expectedUpgradeTxHash = i == 0 ? _systemContractUpgradeTxHash : bytes32(0);
            _lastCommittedBatchData = _commitOneBatch(
                _lastCommittedBatchData,
                _newBatchesData[i],
                expectedUpgradeTxHash
            );

            s.storedBatchHashes[_lastCommittedBatchData.batchNumber] = _hashStoredBatchInfo(_lastCommittedBatchData);
            emit BlockCommit(
                _lastCommittedBatchData.batchNumber,
                _lastCommittedBatchData.batchHash,
                _lastCommittedBatchData.commitment
            );
        }
    }

    /// @dev Pops the priority operations from the priority queue and returns a rolling hash of operations
    function _collectOperationsFromPriorityQueue(uint256 _nPriorityOps) internal returns (bytes32 concatHash) {
        concatHash = EMPTY_STRING_KECCAK;

        for (uint256 i = 0; i < _nPriorityOps; i = i.uncheckedInc()) {
            PriorityOperation memory priorityOp = s.priorityQueue.popFront();
            concatHash = keccak256(abi.encode(concatHash, priorityOp.canonicalTxHash));
        }

        s.priorityTree.skipUntil(s.priorityQueue.getFirstUnprocessedPriorityTx());
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
        bytes32 _priorityOperationsHash
    ) internal view {
        uint256 currentBatchNumber = _storedBatch.batchNumber;
        if (currentBatchNumber != s.totalBatchesExecuted + _executedBatchIdx + 1) {
            revert NonSequentialBatch();
        }
        if (_hashStoredBatchInfo(_storedBatch) != s.storedBatchHashes[currentBatchNumber]) {
            revert BatchHashMismatch(s.storedBatchHashes[currentBatchNumber], _hashStoredBatchInfo(_storedBatch));
        }
        if (_priorityOperationsHash != _storedBatch.priorityOperationsHash) {
            revert PriorityOperationsRollingHashMismatch();
        }
    }

    /// @dev Executes one batch
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes batch on Ethereum
    /// @dev _executedBatchIdx is an index in the array of the batches that we want to execute together
    function _executeOneBatch(StoredBatchInfo memory _storedBatch, uint256 _executedBatchIdx) internal {
        bytes32 priorityOperationsHash = _collectOperationsFromPriorityQueue(_storedBatch.numberOfLayer1Txs);
        _checkBatchData(_storedBatch, _executedBatchIdx, priorityOperationsHash);

        uint256 currentBatchNumber = _storedBatch.batchNumber;

        // Save root hash of L2 -> L1 logs tree
        s.l2LogsRootHashes[currentBatchNumber] = _storedBatch.l2LogsTreeRoot;
        _appendMessageRoot(currentBatchNumber, _storedBatch.l2LogsTreeRoot);
    }

    /// @notice Executes one batch
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes batch
    /// @dev _executedBatchIdx is an index in the array of the batches that we want to execute together
    function _executeOneBatch(
        StoredBatchInfo memory _storedBatch,
        PriorityOpsBatchInfo memory _priorityOpsData,
        uint256 _executedBatchIdx
    ) internal {
        if (_priorityOpsData.itemHashes.length != _storedBatch.numberOfLayer1Txs) {
            revert MismatchNumberOfLayer1Txs(_priorityOpsData.itemHashes.length, _storedBatch.numberOfLayer1Txs);
        }
        bytes32 priorityOperationsHash = _rollingHash(_priorityOpsData.itemHashes);
        _checkBatchData(_storedBatch, _executedBatchIdx, priorityOperationsHash);
        s.priorityTree.processBatch(_priorityOpsData);

        uint256 currentBatchNumber = _storedBatch.batchNumber;

        // Save root hash of L2 -> L1 logs tree
        s.l2LogsRootHashes[currentBatchNumber] = _storedBatch.l2LogsTreeRoot;
        _appendMessageRoot(currentBatchNumber, _storedBatch.l2LogsTreeRoot);
    }

    /// @notice Appends the batch message root to the global message.
    /// @param _batchNumber The number of the batch
    /// @param _messageRoot The root of the merkle tree of the messages to L1.
    /// @dev The logic of this function depends on the settlement layer as we support
    /// message root aggregation only on non-L1 settlement layers for ease for migration.
    function _appendMessageRoot(uint256 _batchNumber, bytes32 _messageRoot) internal {
        // During migration to the new protocol version, there will be a period when
        // the bridgehub does not yet provide the `messageRoot` functionality.
        // To ease up the migration, we never append messages to message root on L1.
        if (block.chainid != L1_CHAIN_ID) {
            // Once the batch is executed, we include its message to the message root.
            IMessageRoot messageRootContract = IBridgehub(s.bridgehub).messageRoot();
            messageRootContract.addChainBatchRoot(s.chainId, _batchNumber, _messageRoot);
        }
    }

    /// @inheritdoc IExecutor
    function executeBatchesSharedBridge(
        uint256, // _chainId
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external nonReentrant onlyValidator onlySettlementLayer {
        (StoredBatchInfo[] memory batchesData, PriorityOpsBatchInfo[] memory priorityOpsData) = BatchDecoder
            .decodeAndCheckExecuteData(_executeData, _processFrom, _processTo);
        uint256 nBatches = batchesData.length;
        if (batchesData.length != priorityOpsData.length) {
            revert InvalidBatchesDataLength(batchesData.length, priorityOpsData.length);
        }

        for (uint256 i = 0; i < nBatches; i = i.uncheckedInc()) {
            if (_isPriorityQueueActive()) {
                if (priorityOpsData[i].leftPath.length != 0) {
                    revert PriorityOpsDataLeftPathLengthIsNotZero();
                }
                if (priorityOpsData[i].rightPath.length != 0) {
                    revert PriorityOpsDataRightPathLengthIsNotZero();
                }
                if (priorityOpsData[i].itemHashes.length != 0) {
                    revert PriorityOpsDataItemHashesLengthIsNotZero();
                }

                _executeOneBatch(batchesData[i], i);
            } else {
                _executeOneBatch(batchesData[i], priorityOpsData[i], i);
            }
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
        uint256, // _chainId
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
        if (_hashStoredBatchInfo(prevBatch) != s.storedBatchHashes[currentTotalBatchesVerified]) {
            revert BatchHashMismatch(s.storedBatchHashes[currentTotalBatchesVerified], _hashStoredBatchInfo(prevBatch));
        }

        bytes32 prevBatchCommitment = prevBatch.commitment;
        for (uint256 i = 0; i < committedBatchesLength; i = i.uncheckedInc()) {
            currentTotalBatchesVerified = currentTotalBatchesVerified.uncheckedInc();
            if (_hashStoredBatchInfo(committedBatches[i]) != s.storedBatchHashes[currentTotalBatchesVerified]) {
                revert BatchHashMismatch(
                    s.storedBatchHashes[currentTotalBatchesVerified],
                    _hashStoredBatchInfo(committedBatches[i])
                );
            }

            bytes32 currentBatchCommitment = committedBatches[i].commitment;
            proofPublicInput[i] = _getBatchProofPublicInput(prevBatchCommitment, currentBatchCommitment);

            prevBatchCommitment = currentBatchCommitment;
        }
        if (currentTotalBatchesVerified > s.totalBatchesCommitted) {
            revert VerifiedBatchesExceedsCommittedBatches();
        }

        _verifyProof(proofPublicInput, proof);

        emit BlocksVerification(s.totalBatchesVerified, currentTotalBatchesVerified);
        s.totalBatchesVerified = currentTotalBatchesVerified;
    }

    function _verifyProof(uint256[] memory proofPublicInput, uint256[] memory _proof) internal view {
        // We can only process 1 batch proof at a time.
        if (proofPublicInput.length != 1) {
            revert CanOnlyProcessOneBatch();
        }

        bool successVerifyProof = s.verifier.verify(proofPublicInput, _proof);
        if (!successVerifyProof) {
            revert InvalidProof();
        }
    }

    /// @dev Gets zk proof public input
    function _getBatchProofPublicInput(
        bytes32 _prevBatchCommitment,
        bytes32 _currentBatchCommitment
    ) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(_prevBatchCommitment, _currentBatchCommitment))) >> PUBLIC_INPUT_SHIFT;
    }

    /// @inheritdoc IExecutor
    function revertBatchesSharedBridge(
        uint256,
        uint256 _newLastBatch
    ) external nonReentrant onlyValidatorOrChainTypeManager {
        _revertBatches(_newLastBatch);
    }

    function _revertBatches(uint256 _newLastBatch) internal onlySettlementLayer {
        if (s.totalBatchesCommitted <= _newLastBatch) {
            revert RevertedBatchNotAfterNewLastBatch();
        }
        if (_newLastBatch < s.totalBatchesExecuted) {
            revert CantRevertExecutedBatch();
        }

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

    /// @notice Returns true if the bit at index {_index} is 1
    function _checkBit(uint256 _bitMap, uint8 _index) internal pure returns (bool) {
        return (_bitMap & (1 << _index)) > 0;
    }

    /// @notice Sets the given bit in {_num} at index {_index} to 1.
    function _setBit(uint256 _bitMap, uint8 _index) internal pure returns (uint256) {
        return _bitMap | (1 << _index);
    }
}
