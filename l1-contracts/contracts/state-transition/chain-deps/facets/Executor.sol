// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBase} from "./ZkSyncHyperchainBase.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, COMMIT_TIMESTAMP_APPROXIMATION_DELTA, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE, MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, PACKED_L2_BLOCK_TIMESTAMP_MASK, PUBLIC_INPUT_SHIFT, POINT_EVALUATION_PRECOMPILE_ADDR} from "../../../common/Config.sol";
import {IExecutor, L2_LOG_ADDRESS_OFFSET, L2_LOG_KEY_OFFSET, L2_LOG_VALUE_OFFSET, SystemLogKey, LogProcessingOutput, PubdataSource, BLS_MODULUS, PUBDATA_COMMITMENT_SIZE, PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET, PUBDATA_COMMITMENT_COMMITMENT_OFFSET, MAX_NUMBER_OF_BLOBS, TOTAL_BLOBS_IN_COMMITMENT, BLOB_SIZE_BYTES} from "../../chain-interfaces/IExecutor.sol";
import {PriorityQueue, PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../../common/libraries/UnsafeBytes.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_PUBDATA_CHUNK_PUBLISHER_ADDR} from "../../../common/L2ContractAddresses.sol";
import {PubdataPricingMode} from "../ZkSyncHyperchainStorage.sol";
import {IStateTransitionManager} from "../../IStateTransitionManager.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZkSyncHyperchainBase} from "../../chain-interfaces/IZkSyncHyperchainBase.sol";

/// @title zkSync hyperchain Executor contract capable of processing events emitted in the zkSync hyperchain protocol.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ExecutorFacet is ZkSyncHyperchainBase, IExecutor {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IZkSyncHyperchainBase
    string public constant override getName = "ExecutorFacet";

    /// @dev Process one batch commit using the previous batch StoredBatchInfo
    /// @dev returns new batch StoredBatchInfo
    /// @notice Does not change storage
    function _commitOneBatch(
        StoredBatchInfo memory _previousBatch,
        CommitBatchInfo calldata _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal view returns (StoredBatchInfo memory) {
        require(_newBatch.batchNumber == _previousBatch.batchNumber + 1, "f"); // only commit next batch

        uint8 pubdataSource = uint8(bytes1(_newBatch.pubdataCommitments[0]));
        PubdataPricingMode pricingMode = s.feeParams.pubdataPricingMode;
        require(
            pricingMode == PubdataPricingMode.Validium ||
                pubdataSource == uint8(PubdataSource.Calldata) ||
                pubdataSource == uint8(PubdataSource.Blob),
            "us"
        );

        // Check that batch contain all meta information for L2 logs.
        // Get the chained hash of priority transaction hashes.
        LogProcessingOutput memory logOutput = _processL2Logs(_newBatch, _expectedSystemContractUpgradeTxHash);

        bytes32[] memory blobCommitments = new bytes32[](MAX_NUMBER_OF_BLOBS);
        if (pricingMode == PubdataPricingMode.Validium) {
            // skipping data validation for validium, we just check that the data is empty
            require(_newBatch.pubdataCommitments.length == 1, "EF: v0l");
            for (uint8 i = uint8(SystemLogKey.BLOB_ONE_HASH_KEY); i <= uint8(SystemLogKey.BLOB_SIX_HASH_KEY); i++) {
                logOutput.blobHashes[i - uint8(SystemLogKey.BLOB_ONE_HASH_KEY)] = bytes32(0);
            }
        } else if (pubdataSource == uint8(PubdataSource.Blob)) {
            // In this scenario, pubdataCommitments is a list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)) = 144 bytes
            blobCommitments = _verifyBlobInformation(_newBatch.pubdataCommitments[1:], logOutput.blobHashes);
        } else if (pubdataSource == uint8(PubdataSource.Calldata)) {
            // In this scenario pubdataCommitments is actual pubdata consisting of l2 to l1 logs, l2 to l1 message, compressed smart contract bytecode, and compressed state diffs
            require(_newBatch.pubdataCommitments.length <= BLOB_SIZE_BYTES, "cz");
            require(
                logOutput.pubdataHash ==
                    keccak256(_newBatch.pubdataCommitments[1:_newBatch.pubdataCommitments.length - 32]),
                "wp"
            );
            blobCommitments[0] = bytes32(
                _newBatch.pubdataCommitments[_newBatch.pubdataCommitments.length - 32:_newBatch
                    .pubdataCommitments
                    .length]
            );
        }

        require(_previousBatch.batchHash == logOutput.previousBatchHash, "l");
        // Check that the priority operation hash in the L2 logs is as expected
        require(logOutput.chainedPriorityTxsHash == _newBatch.priorityOperationsHash, "t");
        // Check that the number of processed priority operations is as expected
        require(logOutput.numberOfLayer1Txs == _newBatch.numberOfLayer1Txs, "ta");

        // Check the timestamp of the new batch
        _verifyBatchTimestamp(logOutput.packedBatchAndL2BlockTimestamp, _newBatch.timestamp, _previousBatch.timestamp);

        // Create batch commitment for the proof verification
        bytes32 commitment = _createBatchCommitment(
            _newBatch,
            logOutput.stateDiffHash,
            blobCommitments,
            logOutput.blobHashes
        );

        return
            StoredBatchInfo({
                batchNumber: _newBatch.batchNumber,
                batchHash: _newBatch.newStateRoot,
                indexRepeatedStorageChanges: _newBatch.indexRepeatedStorageChanges,
                numberOfLayer1Txs: _newBatch.numberOfLayer1Txs,
                priorityOperationsHash: _newBatch.priorityOperationsHash,
                l2LogsTreeRoot: logOutput.l2LogsTreeRoot,
                timestamp: _newBatch.timestamp,
                commitment: commitment
            });
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
        require(batchTimestamp == _expectedBatchTimestamp, "tb");

        // While the fact that _previousBatchTimestamp < batchTimestamp is already checked on L2,
        // we double check it here for clarity
        require(_previousBatchTimestamp < batchTimestamp, "h3");

        uint256 lastL2BlockTimestamp = _packedBatchAndL2BlockTimestamp & PACKED_L2_BLOCK_TIMESTAMP_MASK;

        // All L2 blocks have timestamps within the range of [batchTimestamp, lastL2BlockTimestamp].
        // So here we need to only double check that:
        // - The timestamp of the batch is not too small.
        // - The timestamp of the last L2 block is not too big.
        require(block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER <= batchTimestamp, "h1"); // New batch timestamp is too small
        require(lastL2BlockTimestamp <= block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA, "h2"); // The last L2 block timestamp is too big
    }

    /// @dev Check that L2 logs are proper and batch contain all meta information for them
    /// @dev The logs processed here should line up such that only one log for each key from the
    ///      SystemLogKey enum in Constants.sol is processed per new batch.
    /// @dev Data returned from here will be used to form the batch commitment.
    function _processL2Logs(
        CommitBatchInfo calldata _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal pure returns (LogProcessingOutput memory logOutput) {
        // Copy L2 to L1 logs into memory.
        bytes memory emittedL2Logs = _newBatch.systemLogs;

        logOutput.blobHashes = new bytes32[](MAX_NUMBER_OF_BLOBS);

        // Used as bitmap to set/check log processing happens exactly once.
        // See SystemLogKey enum in Constants.sol for ordering.
        uint256 processedLogs;

        // linear traversal of the logs
        for (uint256 i = 0; i < emittedL2Logs.length; i = i.uncheckedAdd(L2_TO_L1_LOG_SERIALIZE_SIZE)) {
            // Extract the values to be compared to/used such as the log sender, key, and value
            // slither-disable-next-line unused-return
            (address logSender, ) = UnsafeBytes.readAddress(emittedL2Logs, i + L2_LOG_ADDRESS_OFFSET);
            // slither-disable-next-line unused-return
            (uint256 logKey, ) = UnsafeBytes.readUint256(emittedL2Logs, i + L2_LOG_KEY_OFFSET);
            // slither-disable-next-line unused-return
            (bytes32 logValue, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + L2_LOG_VALUE_OFFSET);

            // Ensure that the log hasn't been processed already
            require(!_checkBit(processedLogs, uint8(logKey)), "kp");
            processedLogs = _setBit(processedLogs, uint8(logKey));

            // Need to check that each log was sent by the correct address.
            if (logKey == uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "lm");
                logOutput.l2LogsTreeRoot = logValue;
            } else if (logKey == uint256(SystemLogKey.TOTAL_L2_TO_L1_PUBDATA_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "ln");
                logOutput.pubdataHash = logValue;
            } else if (logKey == uint256(SystemLogKey.STATE_DIFF_HASH_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "lb");
                logOutput.stateDiffHash = logValue;
            } else if (logKey == uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)) {
                require(logSender == L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, "sc");
                logOutput.packedBatchAndL2BlockTimestamp = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.PREV_BATCH_HASH_KEY)) {
                require(logSender == L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, "sv");
                logOutput.previousBatchHash = logValue;
            } else if (logKey == uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bl");
                logOutput.chainedPriorityTxsHash = logValue;
            } else if (logKey == uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bk");
                logOutput.numberOfLayer1Txs = uint256(logValue);
            } else if (
                logKey >= uint256(SystemLogKey.BLOB_ONE_HASH_KEY) && logKey <= uint256(SystemLogKey.BLOB_SIX_HASH_KEY)
            ) {
                require(logSender == L2_PUBDATA_CHUNK_PUBLISHER_ADDR, "pc");
                uint8 blobNumber = uint8(logKey) - uint8(SystemLogKey.BLOB_ONE_HASH_KEY);

                // While the fact that `blobNumber` is a valid blob number is implicitly checked by the fact
                // that Solidity provides array overflow protection, we still double check it manually in case
                // we accidentally put `unchecked` at the top of the loop and generally for better error messages.
                require(blobNumber < MAX_NUMBER_OF_BLOBS, "b6");
                logOutput.blobHashes[blobNumber] = logValue;
            } else if (logKey == uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bu");
                require(_expectedSystemContractUpgradeTxHash == logValue, "ut");
            } else if (logKey > uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY)) {
                revert("ul");
            }
        }

        // We only require 13 logs to be checked, the 14th is if we are expecting a protocol upgrade
        // Without the protocol upgrade we expect 13 logs: 2^13 - 1 = 8191
        // With the protocol upgrade we expect 14 logs: 2^14 - 1 = 16383
        if (_expectedSystemContractUpgradeTxHash == bytes32(0)) {
            require(processedLogs == 8191, "b7");
        } else {
            require(processedLogs == 16383, "b8");
        }
    }

    /// @inheritdoc IExecutor
    function commitBatches(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] calldata _newBatchesData
    ) external nonReentrant onlyValidator {
        _commitBatches(_lastCommittedBatchData, _newBatchesData);
    }

    /// @inheritdoc IExecutor
    function commitBatchesSharedBridge(
        uint256, // _chainId
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] calldata _newBatchesData
    ) external nonReentrant onlyValidator {
        _commitBatches(_lastCommittedBatchData, _newBatchesData);
    }

    function _commitBatches(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] calldata _newBatchesData
    ) internal {
        // check that we have the right protocol version
        // three comments:
        // 1. A chain has to keep their protocol version up to date, as processing a block requires the latest or previous protocol version
        // to solve this we will need to add the feature to create batches with only the protocol upgrade tx, without any other txs.
        // 2. A chain might become out of sync if it launches while we are in the middle of a protocol upgrade. This would mean they cannot process their genesis upgrade
        // as their protocolversion would be outdated, and they also cannot process the protocol upgrade tx as they have a pending upgrade.
        // 3. The protocol upgrade is increased in the BaseZkSyncUpgrade, in the executor only the systemContractsUpgradeTxHash is checked
        require(
            IStateTransitionManager(s.stateTransitionManager).protocolVersionIsActive(s.protocolVersion),
            "Executor facet: wrong protocol version"
        );
        // With the new changes for EIP-4844, namely the restriction on number of blobs per block, we only allow for a single batch to be committed at a time.
        require(_newBatchesData.length == 1, "e4");
        // Check that we commit batches after last committed batch
        require(s.storedBatchHashes[s.totalBatchesCommitted] == _hashStoredBatchInfo(_lastCommittedBatchData), "i"); // incorrect previous batch data

        bytes32 systemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        // Upgrades are rarely done so we optimize a case with no active system contracts upgrade.
        if (systemContractsUpgradeTxHash == bytes32(0) || s.l2SystemContractsUpgradeBatchNumber != 0) {
            _commitBatchesWithoutSystemContractsUpgrade(_lastCommittedBatchData, _newBatchesData);
        } else {
            _commitBatchesWithSystemContractsUpgrade(
                _lastCommittedBatchData,
                _newBatchesData,
                systemContractsUpgradeTxHash
            );
        }

        s.totalBatchesCommitted = s.totalBatchesCommitted + _newBatchesData.length;
    }

    /// @dev Commits new batches without any system contracts upgrade.
    /// @param _lastCommittedBatchData The data of the last committed batch.
    /// @param _newBatchesData An array of batch data that needs to be committed.
    function _commitBatchesWithoutSystemContractsUpgrade(
        StoredBatchInfo memory _lastCommittedBatchData,
        CommitBatchInfo[] calldata _newBatchesData
    ) internal {
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
        CommitBatchInfo[] calldata _newBatchesData,
        bytes32 _systemContractUpgradeTxHash
    ) internal {
        // The system contract upgrade is designed to be executed atomically with the new bootloader, a default account,
        // ZKP verifier, and other system parameters. Hence, we ensure that the upgrade transaction is
        // carried out within the first batch committed after the upgrade.

        // While the logic of the contract ensures that the s.l2SystemContractsUpgradeBatchNumber is 0 when this function is called,
        // this check is added just in case. Since it is a hot read, it does not encure noticeable gas cost.
        require(s.l2SystemContractsUpgradeBatchNumber == 0, "ik");

        // Save the batch number where the upgrade transaction was executed.
        s.l2SystemContractsUpgradeBatchNumber = _newBatchesData[0].batchNumber;

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
    }

    /// @dev Executes one batch
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes batch on Ethereum
    /// @dev _executedBatchIdx is an index in the array of the batches that we want to execute together
    function _executeOneBatch(StoredBatchInfo memory _storedBatch, uint256 _executedBatchIdx) internal {
        uint256 currentBatchNumber = _storedBatch.batchNumber;
        require(currentBatchNumber == s.totalBatchesExecuted + _executedBatchIdx + 1, "k"); // Execute batches in order
        require(
            _hashStoredBatchInfo(_storedBatch) == s.storedBatchHashes[currentBatchNumber],
            "exe10" // executing batch should be committed
        );

        bytes32 priorityOperationsHash = _collectOperationsFromPriorityQueue(_storedBatch.numberOfLayer1Txs);
        require(priorityOperationsHash == _storedBatch.priorityOperationsHash, "x"); // priority operations hash does not match to expected

        // Save root hash of L2 -> L1 logs tree
        s.l2LogsRootHashes[currentBatchNumber] = _storedBatch.l2LogsTreeRoot;
    }

    /// @inheritdoc IExecutor
    function executeBatchesSharedBridge(
        uint256,
        StoredBatchInfo[] calldata _batchesData
    ) external nonReentrant onlyValidator {
        _executeBatches(_batchesData);
    }

    /// @inheritdoc IExecutor
    function executeBatches(StoredBatchInfo[] calldata _batchesData) external nonReentrant onlyValidator {
        _executeBatches(_batchesData);
    }

    function _executeBatches(StoredBatchInfo[] calldata _batchesData) internal {
        uint256 nBatches = _batchesData.length;
        for (uint256 i = 0; i < nBatches; i = i.uncheckedInc()) {
            _executeOneBatch(_batchesData[i], i);
            emit BlockExecution(_batchesData[i].batchNumber, _batchesData[i].batchHash, _batchesData[i].commitment);
        }

        uint256 newTotalBatchesExecuted = s.totalBatchesExecuted + nBatches;
        s.totalBatchesExecuted = newTotalBatchesExecuted;
        require(newTotalBatchesExecuted <= s.totalBatchesVerified, "n"); // Can't execute batches more than committed and proven currently.

        uint256 batchWhenUpgradeHappened = s.l2SystemContractsUpgradeBatchNumber;
        if (batchWhenUpgradeHappened != 0 && batchWhenUpgradeHappened <= newTotalBatchesExecuted) {
            delete s.l2SystemContractsUpgradeTxHash;
            delete s.l2SystemContractsUpgradeBatchNumber;
        }
    }

    /// @inheritdoc IExecutor
    function proveBatches(
        StoredBatchInfo calldata _prevBatch,
        StoredBatchInfo[] calldata _committedBatches,
        ProofInput calldata _proof
    ) external nonReentrant onlyValidator {
        _proveBatches(_prevBatch, _committedBatches, _proof);
    }

    /// @inheritdoc IExecutor
    function proveBatchesSharedBridge(
        uint256, // _chainId
        StoredBatchInfo calldata _prevBatch,
        StoredBatchInfo[] calldata _committedBatches,
        ProofInput calldata _proof
    ) external nonReentrant onlyValidator {
        _proveBatches(_prevBatch, _committedBatches, _proof);
    }

    function _proveBatches(
        StoredBatchInfo calldata _prevBatch,
        StoredBatchInfo[] calldata _committedBatches,
        ProofInput calldata _proof
    ) internal {
        // Save the variables into the stack to save gas on reading them later
        uint256 currentTotalBatchesVerified = s.totalBatchesVerified;
        uint256 committedBatchesLength = _committedBatches.length;

        // Initialize the array, that will be used as public input to the ZKP
        uint256[] memory proofPublicInput = new uint256[](committedBatchesLength);

        // Check that the batch passed by the validator is indeed the first unverified batch
        require(_hashStoredBatchInfo(_prevBatch) == s.storedBatchHashes[currentTotalBatchesVerified], "t1");

        bytes32 prevBatchCommitment = _prevBatch.commitment;
        for (uint256 i = 0; i < committedBatchesLength; i = i.uncheckedInc()) {
            currentTotalBatchesVerified = currentTotalBatchesVerified.uncheckedInc();
            require(
                _hashStoredBatchInfo(_committedBatches[i]) == s.storedBatchHashes[currentTotalBatchesVerified],
                "o1"
            );

            bytes32 currentBatchCommitment = _committedBatches[i].commitment;
            proofPublicInput[i] = _getBatchProofPublicInput(prevBatchCommitment, currentBatchCommitment);

            prevBatchCommitment = currentBatchCommitment;
        }
        require(currentTotalBatchesVerified <= s.totalBatchesCommitted, "q");

        _verifyProof(proofPublicInput, _proof);

        emit BlocksVerification(s.totalBatchesVerified, currentTotalBatchesVerified);
        s.totalBatchesVerified = currentTotalBatchesVerified;
    }

    function _verifyProof(uint256[] memory proofPublicInput, ProofInput calldata _proof) internal view {
        // We can only process 1 batch proof at a time.
        require(proofPublicInput.length == 1, "t4");

        bool successVerifyProof = s.verifier.verify(
            proofPublicInput,
            _proof.serializedProof,
            _proof.recursiveAggregationInput
        );
        require(successVerifyProof, "p"); // Proof verification fail
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
    function revertBatches(uint256 _newLastBatch) external nonReentrant onlyValidatorOrStateTransitionManager {
        _revertBatches(_newLastBatch);
    }

    /// @inheritdoc IExecutor
    function revertBatchesSharedBridge(uint256, uint256 _newLastBatch) external nonReentrant onlyValidator {
        _revertBatches(_newLastBatch);
    }

    function _revertBatches(uint256 _newLastBatch) internal {
        require(s.totalBatchesCommitted > _newLastBatch, "v1"); // The last committed batch is less than new last batch
        require(_newLastBatch >= s.totalBatchesExecuted, "v2"); // Already executed batches cannot be reverted

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
        CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal view returns (bytes32) {
        bytes32 passThroughDataHash = keccak256(_batchPassThroughData(_newBatchData));
        bytes32 metadataHash = keccak256(_batchMetaParameters());
        bytes32 auxiliaryOutputHash = keccak256(
            _batchAuxiliaryOutput(_newBatchData, _stateDiffHash, _blobCommitments, _blobHashes)
        );

        return keccak256(abi.encode(passThroughDataHash, metadataHash, auxiliaryOutputHash));
    }

    function _batchPassThroughData(CommitBatchInfo calldata _batch) internal pure returns (bytes memory) {
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
        bytes32 l2DefaultAccountBytecodeHash = s.l2DefaultAccountBytecodeHash;
        return
            abi.encodePacked(
                s.zkPorterIsAvailable,
                s.l2BootloaderBytecodeHash,
                l2DefaultAccountBytecodeHash,
                // VM 1.5.0 requires us to pass the EVM simulator code hash. For now it is the same as the default account.
                l2DefaultAccountBytecodeHash
            );
    }

    function _batchAuxiliaryOutput(
        CommitBatchInfo calldata _batch,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) internal pure returns (bytes memory) {
        require(_batch.systemLogs.length <= MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, "pu");

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
        require(_blobCommitments.length == MAX_NUMBER_OF_BLOBS, "b10");
        require(_blobHashes.length == MAX_NUMBER_OF_BLOBS, "b11");

        // for each blob we have:
        // linear hash (hash of preimage from system logs) and
        // output hash of blob commitments: keccak(versioned hash || opening point || evaluation value)
        // These values will all be bytes32(0) when we submit pubdata via calldata instead of blobs.
        //
        // For now, only up to 6 blobs are supported by the contract, while 16 are required by the circuits.
        // All the unfilled blobs will have their commitment as 0, including the case when we use only 1 blob.

        blobAuxOutputWords = new bytes32[](2 * TOTAL_BLOBS_IN_COMMITMENT);

        for (uint256 i = 0; i < MAX_NUMBER_OF_BLOBS; i++) {
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

    /// @notice Calls the point evaluation precompile and verifies the output
    /// Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
    /// Also verify that the provided commitment matches the provided versioned_hash.
    ///
    function _pointEvaluationPrecompile(
        bytes32 _versionedHash,
        bytes32 _openingPoint,
        bytes calldata _openingValueCommitmentProof
    ) internal view {
        bytes memory precompileInput = abi.encodePacked(_versionedHash, _openingPoint, _openingValueCommitmentProof);

        (bool success, bytes memory data) = POINT_EVALUATION_PRECOMPILE_ADDR.staticcall(precompileInput);

        // We verify that the point evaluation precompile call was successful by testing the latter 32 bytes of the
        // response is equal to BLS_MODULUS as defined in https://eips.ethereum.org/EIPS/eip-4844#point-evaluation-precompile
        require(success, "failed to call point evaluation precompile");
        (, uint256 result) = abi.decode(data, (uint256, uint256));
        require(result == BLS_MODULUS, "precompile unexpected output");
    }

    /// @dev Verifies that the blobs contain the correct data by calling the point evaluation precompile. For the precompile we need:
    /// versioned hash || opening point || opening value || commitment || proof
    /// the _pubdataCommitments will contain the last 4 values, the versioned hash is pulled from the BLOBHASH opcode
    /// pubdataCommitments is a list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)) = 144 bytes
    function _verifyBlobInformation(
        bytes calldata _pubdataCommitments,
        bytes32[] memory _blobHashes
    ) internal view returns (bytes32[] memory blobCommitments) {
        uint256 versionedHashIndex = 0;

        require(_pubdataCommitments.length > 0, "pl");
        require(_pubdataCommitments.length <= PUBDATA_COMMITMENT_SIZE * MAX_NUMBER_OF_BLOBS, "bd");
        require(_pubdataCommitments.length % PUBDATA_COMMITMENT_SIZE == 0, "bs");
        blobCommitments = new bytes32[](MAX_NUMBER_OF_BLOBS);

        for (uint256 i = 0; i < _pubdataCommitments.length; i += PUBDATA_COMMITMENT_SIZE) {
            bytes32 blobVersionedHash = _getBlobVersionedHash(versionedHashIndex);

            require(blobVersionedHash != bytes32(0), "vh");

            // First 16 bytes is the opening point. While we get the point as 16 bytes, the point evaluation precompile
            // requires it to be 32 bytes. The blob commitment must use the opening point as 16 bytes though.
            bytes32 openingPoint = bytes32(
                uint256(uint128(bytes16(_pubdataCommitments[i:i + PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET])))
            );

            _pointEvaluationPrecompile(
                blobVersionedHash,
                openingPoint,
                _pubdataCommitments[i + PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET:i + PUBDATA_COMMITMENT_SIZE]
            );

            // Take the hash of the versioned hash || opening point || claimed value
            blobCommitments[versionedHashIndex] = keccak256(
                abi.encodePacked(blobVersionedHash, _pubdataCommitments[i:i + PUBDATA_COMMITMENT_COMMITMENT_OFFSET])
            );
            versionedHashIndex += 1;
        }

        // This check is required because we want to ensure that there aren't any extra blobs trying to be published.
        // Calling the BLOBHASH opcode with an index > # blobs - 1 yields bytes32(0)
        bytes32 versionedHash = _getBlobVersionedHash(versionedHashIndex);
        require(versionedHash == bytes32(0), "lh");

        // We verify that for each set of blobHash/blobCommitment are either both empty
        // or there are values for both.
        for (uint256 i = 0; i < MAX_NUMBER_OF_BLOBS; i++) {
            require(
                (_blobHashes[i] == bytes32(0) && blobCommitments[i] == bytes32(0)) ||
                    (_blobHashes[i] != bytes32(0) && blobCommitments[i] != bytes32(0)),
                "bh"
            );
        }
    }

    function _getBlobVersionedHash(uint256 _index) internal view virtual returns (bytes32 versionedHash) {
        assembly {
            versionedHash := blobhash(_index)
        }
    }
}
