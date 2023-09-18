// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Base} from "./Base.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, COMMIT_TIMESTAMP_APPROXIMATION_DELTA, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE, INPUT_MASK, MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES, MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES, MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, PACKED_L2_BLOCK_TIMESTAMP_MASK} from "../Config.sol";
import {IExecutor, L2_LOG_ADDRESS_OFFSET, L2_LOG_KEY_OFFSET, L2_LOG_VALUE_OFFSET, SystemLogKey} from "../interfaces/IExecutor.sol";
import {PriorityQueue, PriorityOperation} from "../libraries/PriorityQueue.sol";
import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../common/libraries/UnsafeBytes.sol";
import {L2ContractHelper} from "../../common/libraries/L2ContractHelper.sol";
import {VerifierParams} from "../Storage.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR} from "../../common/L2ContractAddresses.sol";

/// @title zkSync Executor contract capable of processing events emitted in the zkSync protocol.
/// @author Matter Labs
contract ExecutorFacet is Base, IExecutor {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    string public constant override getName = "ExecutorFacet";

    /// @dev Process one block commit using the previous block StoredBlockInfo
    /// @dev returns new block StoredBlockInfo
    /// @notice Does not change storage
    function _commitOneBlock(
        StoredBlockInfo memory _previousBlock,
        CommitBlockInfo calldata _newBlock,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal view returns (StoredBlockInfo memory) {
        require(_newBlock.blockNumber == _previousBlock.blockNumber + 1, "f"); // only commit next block

        // Check that block contain all meta information for L2 logs.
        // Get the chained hash of priority transaction hashes.
        (
            uint256 expectedNumberOfLayer1Txs,
            bytes32 expectedPriorityOperationsHash,
            bytes32 previousBlockHash,
            bytes32 stateDiffHash,
            bytes32 l2LogsTreeRoot,
            uint256 packedBatchAndL2BlockTimestamp
        ) = _processL2Logs(_newBlock, _expectedSystemContractUpgradeTxHash);

        require(_previousBlock.blockHash == previousBlockHash, "l");
        // Check that the priority operation hash in the L2 logs is as expected
        require(expectedPriorityOperationsHash == _newBlock.priorityOperationsHash, "t");
        // Check that the number of processed priority operations is as expected
        require(expectedNumberOfLayer1Txs == _newBlock.numberOfLayer1Txs, "ta");

        // Check the timestamp of the new block
        _verifyBlockTimestamp(packedBatchAndL2BlockTimestamp, _newBlock.timestamp, _previousBlock.timestamp);

        // Create block commitment for the proof verification
        bytes32 commitment = _createBlockCommitment(_newBlock, stateDiffHash);

        return
            StoredBlockInfo(
                _newBlock.blockNumber,
                _newBlock.newStateRoot,
                _newBlock.indexRepeatedStorageChanges,
                _newBlock.numberOfLayer1Txs,
                _newBlock.priorityOperationsHash,
                l2LogsTreeRoot,
                _newBlock.timestamp,
                commitment
            );
    }

    /// @notice checks that the timestamps of both the new batch and the new L2 block are correct.
    /// @param _packedBatchAndL2BlockTimestamp - packed batch and L2 block timestamp in a foramt of batchTimestamp * 2**128 + l2BlockTimestamp
    /// @param _expectedBatchTimestamp - expected batch timestamp
    /// @param _previousBatchTimestamp - the timestamp of the previous batch
    function _verifyBlockTimestamp(
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

        // On L2, all blocks have timestamps within the range of [batchTimestamp, lastL2BlockTimestamp].
        // So here we need to only double check that:
        // - The timestamp of the batch is not too small.
        // - The timestamp of the last L2 block is not too big.
        require(block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER <= batchTimestamp, "h1"); // New batch timestamp is too small
        require(lastL2BlockTimestamp <= block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA, "h2"); // The last L2 block timestamp is too big
    }

    /// @dev Check that L2 logs are proper and block contain all meta information for them
    /// @dev The logs processed here should line up such that only one log for each key from the
    ///      SystemLogKey enum in Constants.sol is processed per new block.
    /// @dev Data returned from here will be used to form the block commitment.
    function _processL2Logs(CommitBlockInfo calldata _newBlock, bytes32 _expectedSystemContractUpgradeTxHash)
        internal
        pure
        returns (
            uint256 numberOfLayer1Txs,
            bytes32 chainedPriorityTxsHash,
            bytes32 previousBlockHash,
            bytes32 stateDiffHash,
            bytes32 l2LogsTreeRoot,
            uint256 packedBatchAndL2BlockTimestamp
        )
    {
        // Copy L2 to L1 logs into memory.
        bytes memory emittedL2Logs = _newBlock.systemLogs[4:];

        // Used as bitmap to set/check log processing happens exactly once.
        // See SystemLogKey enum in Constants.sol for ordering.
        uint256 processedLogs;

        bytes32 providedL2ToL1PubdataHash = keccak256(_newBlock.totalL2ToL1Pubdata);

        // linear traversal of the logs
        for (uint256 i = 0; i < emittedL2Logs.length; i = i.uncheckedAdd(L2_TO_L1_LOG_SERIALIZE_SIZE)) {
            // Extract the values to be compared to/used such as the log sender, key, and value
            (address logSender, ) = UnsafeBytes.readAddress(emittedL2Logs, i + L2_LOG_ADDRESS_OFFSET);
            (uint256 logKey, ) = UnsafeBytes.readUint256(emittedL2Logs, i + L2_LOG_KEY_OFFSET);
            (bytes32 logValue, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + L2_LOG_VALUE_OFFSET);

            // Ensure that the log hasn't been processed already
            require(!_checkBit(processedLogs, uint8(logKey)), "kp");
            processedLogs = _setBit(processedLogs, uint8(logKey));

            // Need to check that each log was sent by the correct address.
            if (logKey == uint256(SystemLogKey.L2_TO_L1_LOGS_TREE_ROOT_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "lm");
                l2LogsTreeRoot = logValue;
            } else if (logKey == uint256(SystemLogKey.TOTAL_L2_TO_L1_PUBDATA_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "ln");
                require(providedL2ToL1PubdataHash == logValue, "wp");
            } else if (logKey == uint256(SystemLogKey.STATE_DIFF_HASH_KEY)) {
                require(logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "lb");
                stateDiffHash = logValue;
            } else if (logKey == uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)) {
                require(logSender == L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, "sc");
                packedBatchAndL2BlockTimestamp = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.PREV_BLOCK_HASH_KEY)) {
                require(logSender == L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, "sv");
                previousBlockHash = logValue;
            } else if (logKey == uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bl");
                chainedPriorityTxsHash = logValue;
            } else if (logKey == uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bk");
                numberOfLayer1Txs = uint256(logValue);
            } else if (logKey == uint256(SystemLogKey.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH)) {
                require(logSender == L2_BOOTLOADER_ADDRESS, "bu");
                require(_expectedSystemContractUpgradeTxHash == logValue, "ut");
            } else {
                revert("ul");
            }
        }

        // We only require 7 logs to be checked, the 8th is if we are expecting a protocol upgrade
        // Without the protocol upgrade we expect 7 logs: 2^7 - 1 = 127
        // With the protocol upgrade we expect 8 logs: 2^8 - 1 = 255
        if (_expectedSystemContractUpgradeTxHash == bytes32(0)) {
            require(processedLogs == 127, "b7");
        } else {
            require(processedLogs == 255, "b8");
        }
    }

    /// @notice Commit block
    /// @notice 1. Checks timestamp.
    /// @notice 2. Process L2 logs.
    /// @notice 3. Store block commitments.
    function commitBlocks(StoredBlockInfo memory _lastCommittedBlockData, CommitBlockInfo[] calldata _newBlocksData)
        external
        override
        nonReentrant
        onlyValidator
    {
        // Check that we commit blocks after last committed block
        require(s.storedBlockHashes[s.totalBlocksCommitted] == _hashStoredBlockInfo(_lastCommittedBlockData), "i"); // incorrect previous block data
        require(_newBlocksData.length > 0, "No blocks to commit");

        bytes32 systemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        // Upgrades are rarely done so we optimize a case with no active system contracts upgrade.
        if (systemContractsUpgradeTxHash == bytes32(0) || s.l2SystemContractsUpgradeBlockNumber != 0) {
            _commitBlocksWithoutSystemContractsUpgrade(_lastCommittedBlockData, _newBlocksData);
        } else {
            _commitBlocksWithSystemContractsUpgrade(
                _lastCommittedBlockData,
                _newBlocksData,
                systemContractsUpgradeTxHash
            );
        }

        s.totalBlocksCommitted = s.totalBlocksCommitted + _newBlocksData.length;
    }

    /// @dev Commits new blocks without any system contracts upgrade.
    /// @param _lastCommittedBlockData The data of the last committed block.
    /// @param _newBlocksData An array of block data that needs to be committed.
    function _commitBlocksWithoutSystemContractsUpgrade(
        StoredBlockInfo memory _lastCommittedBlockData,
        CommitBlockInfo[] calldata _newBlocksData
    ) internal {
        for (uint256 i = 0; i < _newBlocksData.length; i = i.uncheckedInc()) {
            _lastCommittedBlockData = _commitOneBlock(_lastCommittedBlockData, _newBlocksData[i], bytes32(0));

            s.storedBlockHashes[_lastCommittedBlockData.blockNumber] = _hashStoredBlockInfo(_lastCommittedBlockData);
            emit BlockCommit(
                _lastCommittedBlockData.blockNumber,
                _lastCommittedBlockData.blockHash,
                _lastCommittedBlockData.commitment
            );
        }
    }

    /// @dev Commits new blocks with a system contracts upgrade transaction.
    /// @param _lastCommittedBlockData The data of the last committed block.
    /// @param _newBlocksData An array of block data that needs to be committed.
    /// @param _systemContractUpgradeTxHash The transaction hash of the system contract upgrade.
    function _commitBlocksWithSystemContractsUpgrade(
        StoredBlockInfo memory _lastCommittedBlockData,
        CommitBlockInfo[] calldata _newBlocksData,
        bytes32 _systemContractUpgradeTxHash
    ) internal {
        // The system contract upgrade is designed to be executed atomically with the new bootloader, a default account,
        // ZKP verifier, and other system parameters. Hence, we ensure that the upgrade transaction is
        // carried out within the first block committed after the upgrade.

        // While the logic of the contract ensures that the s.l2SystemContractsUpgradeBlockNumber is 0 when this function is called,
        // this check is added just in case. Since it is a hot read, it does not encure noticable gas cost.
        require(s.l2SystemContractsUpgradeBlockNumber == 0, "ik");

        // Save the block number where the upgrade transaction was executed.
        s.l2SystemContractsUpgradeBlockNumber = _newBlocksData[0].blockNumber;

        for (uint256 i = 0; i < _newBlocksData.length; i = i.uncheckedInc()) {
            // The upgrade transaction must only be included in the first block.
            bytes32 expectedUpgradeTxHash = i == 0 ? _systemContractUpgradeTxHash : bytes32(0);
            _lastCommittedBlockData = _commitOneBlock(
                _lastCommittedBlockData,
                _newBlocksData[i],
                expectedUpgradeTxHash
            );

            s.storedBlockHashes[_lastCommittedBlockData.blockNumber] = _hashStoredBlockInfo(_lastCommittedBlockData);
            emit BlockCommit(
                _lastCommittedBlockData.blockNumber,
                _lastCommittedBlockData.blockHash,
                _lastCommittedBlockData.commitment
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

    /// @dev Executes one block
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes block on Ethereum
    /// @dev _executedBlockIdx is an index in the array of the blocks that we want to execute together
    function _executeOneBlock(StoredBlockInfo memory _storedBlock, uint256 _executedBlockIdx) internal {
        uint256 currentBlockNumber = _storedBlock.blockNumber;
        require(currentBlockNumber == s.totalBlocksExecuted + _executedBlockIdx + 1, "k"); // Execute blocks in order
        require(
            _hashStoredBlockInfo(_storedBlock) == s.storedBlockHashes[currentBlockNumber],
            "exe10" // executing block should be committed
        );

        bytes32 priorityOperationsHash = _collectOperationsFromPriorityQueue(_storedBlock.numberOfLayer1Txs);
        require(priorityOperationsHash == _storedBlock.priorityOperationsHash, "x"); // priority operations hash does not match to expected

        // Save root hash of L2 -> L1 logs tree
        s.l2LogsRootHashes[currentBlockNumber] = _storedBlock.l2LogsTreeRoot;
    }

    /// @notice Execute blocks, complete priority operations and process withdrawals.
    /// @notice 1. Processes all pending operations (Complete priority requests)
    /// @notice 2. Finalizes block on Ethereum
    function executeBlocks(StoredBlockInfo[] calldata _blocksData) external nonReentrant onlyValidator {
        uint256 nBlocks = _blocksData.length;
        for (uint256 i = 0; i < nBlocks; i = i.uncheckedInc()) {
            _executeOneBlock(_blocksData[i], i);
            emit BlockExecution(_blocksData[i].blockNumber, _blocksData[i].blockHash, _blocksData[i].commitment);
        }

        uint256 newTotalBlocksExecuted = s.totalBlocksExecuted + nBlocks;
        s.totalBlocksExecuted = newTotalBlocksExecuted;
        require(newTotalBlocksExecuted <= s.totalBlocksVerified, "n"); // Can't execute blocks more than committed and proven currently.

        uint256 blockWhenUpgradeHappened = s.l2SystemContractsUpgradeBlockNumber;
        if (blockWhenUpgradeHappened != 0 && blockWhenUpgradeHappened <= newTotalBlocksExecuted) {
            delete s.l2SystemContractsUpgradeTxHash;
            delete s.l2SystemContractsUpgradeBlockNumber;
        }
    }

    /// @notice Blocks commitment verification.
    /// @notice Only verifies block commitments without any other processing
    function proveBlocks(
        StoredBlockInfo calldata _prevBlock,
        StoredBlockInfo[] calldata _committedBlocks,
        ProofInput calldata _proof
    ) external nonReentrant onlyValidator {
        // Save the variables into the stack to save gas on reading them later
        uint256 currentTotalBlocksVerified = s.totalBlocksVerified;
        uint256 committedBlocksLength = _committedBlocks.length;

        // Save the variable from the storage to memory to save gas
        VerifierParams memory verifierParams = s.verifierParams;

        // Initialize the array, that will be used as public input to the ZKP
        uint256[] memory proofPublicInput = new uint256[](committedBlocksLength);

        // Check that the block passed by the validator is indeed the first unverified block
        require(_hashStoredBlockInfo(_prevBlock) == s.storedBlockHashes[currentTotalBlocksVerified], "t1");

        bytes32 prevBlockCommitment = _prevBlock.commitment;
        for (uint256 i = 0; i < committedBlocksLength; i = i.uncheckedInc()) {
            currentTotalBlocksVerified = currentTotalBlocksVerified.uncheckedInc();
            require(_hashStoredBlockInfo(_committedBlocks[i]) == s.storedBlockHashes[currentTotalBlocksVerified], "o1");

            bytes32 currentBlockCommitment = _committedBlocks[i].commitment;
            proofPublicInput[i] = _getBlockProofPublicInput(
                prevBlockCommitment,
                currentBlockCommitment,
                _proof,
                verifierParams
            );

            prevBlockCommitment = currentBlockCommitment;
        }
        require(currentTotalBlocksVerified <= s.totalBlocksCommitted, "q");

        // #if DUMMY_VERIFIER

        // Additional level of protection for the mainnet
        assert(block.chainid != 1);
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.serializedProof.length > 0) {
            bool successVerifyProof = s.verifier.verify(
                proofPublicInput,
                _proof.serializedProof,
                _proof.recursiveAggregationInput
            );
            require(successVerifyProof, "p"); // Proof verification fail
        }
        // #else
        bool successVerifyProof = s.verifier.verify(
            proofPublicInput,
            _proof.serializedProof,
            _proof.recursiveAggregationInput
        );
        require(successVerifyProof, "p"); // Proof verification fail
        // #endif

        emit BlocksVerification(s.totalBlocksVerified, currentTotalBlocksVerified);
        s.totalBlocksVerified = currentTotalBlocksVerified;
    }

    /// @dev Gets zk proof public input
    function _getBlockProofPublicInput(
        bytes32 _prevBlockCommitment,
        bytes32 _currentBlockCommitment,
        ProofInput calldata _proof,
        VerifierParams memory _verifierParams
    ) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        _prevBlockCommitment,
                        _currentBlockCommitment,
                        _verifierParams.recursionNodeLevelVkHash,
                        _verifierParams.recursionLeafLevelVkHash
                    )
                )
            ) & INPUT_MASK;
    }

    /// @notice Reverts unexecuted blocks
    /// @param _newLastBlock block number after which blocks should be reverted
    /// NOTE: Doesn't delete the stored data about blocks, but only decreases
    /// counters that are responsible for the number of blocks
    function revertBlocks(uint256 _newLastBlock) external nonReentrant onlyValidator {
        require(s.totalBlocksCommitted > _newLastBlock, "v1"); // The last committed block is less than new last block
        uint256 newTotalBlocksCommitted = _maxU256(_newLastBlock, s.totalBlocksExecuted);

        if (newTotalBlocksCommitted < s.totalBlocksVerified) {
            s.totalBlocksVerified = newTotalBlocksCommitted;
        }
        s.totalBlocksCommitted = newTotalBlocksCommitted;

        // Reset the block number of the executed system contracts upgrade transaction if the block
        // where the system contracts upgrade was committed is among the reverted blocks.
        if (s.l2SystemContractsUpgradeBlockNumber > newTotalBlocksCommitted) {
            delete s.l2SystemContractsUpgradeBlockNumber;
        }

        emit BlocksRevert(s.totalBlocksCommitted, s.totalBlocksVerified, s.totalBlocksExecuted);
    }

    /// @notice Returns larger of two values
    function _maxU256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? b : a;
    }

    /// @dev Creates block commitment from its data
    function _createBlockCommitment(CommitBlockInfo calldata _newBlockData, bytes32 _stateDiffHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 passThroughDataHash = keccak256(_blockPassThroughData(_newBlockData));
        bytes32 metadataHash = keccak256(_blockMetaParameters());
        bytes32 auxiliaryOutputHash = keccak256(_blockAuxiliaryOutput(_newBlockData, _stateDiffHash));

        return keccak256(abi.encode(passThroughDataHash, metadataHash, auxiliaryOutputHash));
    }

    function _blockPassThroughData(CommitBlockInfo calldata _block) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _block.indexRepeatedStorageChanges,
                _block.newStateRoot,
                uint64(0), // index repeated storage changes in zkPorter
                bytes32(0) // zkPorter block hash
            );
    }

    function _blockMetaParameters() internal view returns (bytes memory) {
        return abi.encodePacked(s.zkPorterIsAvailable, s.l2BootloaderBytecodeHash, s.l2DefaultAccountBytecodeHash);
    }

    function _blockAuxiliaryOutput(CommitBlockInfo calldata _block, bytes32 _stateDiffHash)
        internal
        pure
        returns (bytes memory)
    {
        require(_block.systemLogs.length <= MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, "pu");

        bytes32 l2ToL1LogsHash = keccak256(_block.systemLogs);

        return abi.encode(
            l2ToL1LogsHash, 
            _stateDiffHash,
            _block.bootloaderHeapInitialContentsHash,
            _block.eventsQueueStateHash
        );
    }

    /// @notice Returns the keccak hash of the ABI-encoded StoredBlockInfo
    function _hashStoredBlockInfo(StoredBlockInfo memory _storedBlockInfo) internal pure returns (bytes32) {
        return keccak256(abi.encode(_storedBlockInfo));
    }

    /// @notice Returns if the bit at index {_index} is 1
    function _checkBit(uint256 _bitMap, uint8 _index) internal pure returns (bool) {
        return (_bitMap & (1 << _index)) > 0;
    }

    /// @notice Sets the given bit in {_num} at index {_index} to 1.
    function _setBit(uint256 _num, uint8 _index) internal pure returns (uint256) {
        return _num | (1 << _index);
    }
}
