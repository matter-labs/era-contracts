// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ProofChainBase.sol";
import "../../chain-interfaces/IProofChainExecutor.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, COMMIT_TIMESTAMP_APPROXIMATION_DELTA, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE, INPUT_MASK, MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES, MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES, MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, PACKED_L2_BLOCK_TIMESTAMP_MASK} from "../../Config.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../../common/libraries/UnsafeBytes.sol";
import {L2ContractHelper} from "../../../common/libraries/L2ContractHelper.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR} from "../../../common/L2ContractAddresses.sol";

/// @title zkSync Executor contract capable of processing events emitted in the zkSync protocol.
/// @author Matter Labs
contract ProofExecutorFacet is ProofChainBase, IProofExecutor {
    using UncheckedMath for uint256;

    // string public constant override getName = "ExecutorFacet";
    uint256 public val;

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
            uint256 packedBatchAndL2BlockTimestamp
        ) = _processL2Logs(_newBlock, _expectedSystemContractUpgradeTxHash);

        require(_previousBlock.blockHash == previousBlockHash, "l");
        // Check that the priority operation hash in the L2 logs is as expected
        require(expectedPriorityOperationsHash == _newBlock.priorityOperationsHash, "t");
        // Check that the number of processed priority operations is as expected
        require(expectedNumberOfLayer1Txs == _newBlock.numberOfLayer1Txs, "ta");

        // Check the timestamp osf the new block
        _verifyBlockTimestamp(packedBatchAndL2BlockTimestamp, _newBlock.timestamp, _previousBlock.timestamp);

        // Preventing "stack too deep error"
        {
            // Check the index of repeated storage writes
            uint256 newStorageChangesIndexes = uint256(uint32(bytes4(_newBlock.initialStorageChanges[:4])));
            require(
                _previousBlock.indexRepeatedStorageChanges + newStorageChangesIndexes ==
                    _newBlock.indexRepeatedStorageChanges,
                "yq"
            );
        }

        // Create block commitment for the proof verification
        bytes32 commitment = _createBlockCommitment(_newBlock);

        return
            StoredBlockInfo(
                _newBlock.blockNumber,
                _newBlock.newStateRoot,
                _newBlock.indexRepeatedStorageChanges,
                _newBlock.numberOfLayer1Txs,
                _newBlock.priorityOperationsHash,
                _newBlock.l2LogsTreeRoot,
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
        require(_previousBatchTimestamp < batchTimestamp, "h");

        uint256 lastL2BlockTimestamp = _packedBatchAndL2BlockTimestamp & PACKED_L2_BLOCK_TIMESTAMP_MASK;

        // On L2, all blocks have timestamps within the range of [batchTimestamp, lastL2BlockTimestamp].
        // So here we need to only double check that:
        // - The timestamp of the batch is not too small.
        // - The timestamp of the last L2 block is not too big.
        require(block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER <= batchTimestamp, "h1"); // New batch timestamp is too small
        require(lastL2BlockTimestamp <= block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA, "h2"); // The last L2 block timestamp is too big
    }

    /// @dev Check that L2 logs are proper and block contain all meta information for them
    function _processL2Logs(CommitBlockInfo calldata _newBlock, bytes32 _expectedSystemContractUpgradeTxHash)
        internal
        pure
        returns (
            uint256 numberOfLayer1Txs,
            bytes32 chainedPriorityTxsHash,
            bytes32 previousBlockHash,
            uint256 packedBatchAndL2BlockTimestamp
        )
    {
        // Copy L2 to L1 logs into memory.
        bytes memory emittedL2Logs = _newBlock.l2Logs[4:];
        uint256 currentMessage;
        // Auxiliary variable that is needed to enforce that `previousBlockHash` and `blockTimestamp` was read exactly one time
        bool isSystemContextLogProcessed;
        bytes[] calldata factoryDeps = _newBlock.factoryDeps;
        uint256 currentBytecode;

        chainedPriorityTxsHash = EMPTY_STRING_KECCAK;

        // linear traversal of the logs
        for (uint256 i = 0; i < emittedL2Logs.length; i = i.uncheckedAdd(L2_TO_L1_LOG_SERIALIZE_SIZE)) {
            (address logSender, ) = UnsafeBytes.readAddress(emittedL2Logs, i + 4);

            // show preimage for hashed message stored in log
            if (logSender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                (bytes32 hashedMessage, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 56);
                require(keccak256(_newBlock.l2ArbitraryLengthMessages[currentMessage]) == hashedMessage, "k2");

                currentMessage = currentMessage.uncheckedInc();
            } else if (logSender == L2_BOOTLOADER_ADDRESS) {
                (bytes32 canonicalTxHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 24);

                if (_expectedSystemContractUpgradeTxHash != bytes32(0)) {
                    require(_expectedSystemContractUpgradeTxHash == canonicalTxHash, "bz");
                    _expectedSystemContractUpgradeTxHash = bytes32(0);
                } else {
                    chainedPriorityTxsHash = keccak256(abi.encode(chainedPriorityTxsHash, canonicalTxHash));
                    // Overflow is not realistic
                    numberOfLayer1Txs = numberOfLayer1Txs.uncheckedInc();
                }
            } else if (logSender == L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR) {
                // Make sure that the system context log wasn't processed yet, to
                // avoid accident double reading `blockTimestamp` and `previousBlockHash`
                require(!isSystemContextLogProcessed, "fx");
                (packedBatchAndL2BlockTimestamp, ) = UnsafeBytes.readUint256(emittedL2Logs, i + 24);
                (previousBlockHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 56);
                // Mark system context log as processed
                isSystemContextLogProcessed = true;
            } else if (logSender == L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR) {
                (bytes32 bytecodeHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 24);
                require(bytecodeHash == L2ContractHelper.hashL2Bytecode(factoryDeps[currentBytecode]), "k3");

                currentBytecode = currentBytecode.uncheckedInc();
            } else {
                // Only some system contracts could send raw logs from L2 to L1, double check that invariant holds here.
                revert("ne");
            }
        }
        // To check that only relevant preimages have been included in the calldata
        require(currentBytecode == factoryDeps.length, "ym");
        require(currentMessage == _newBlock.l2ArbitraryLengthMessages.length, "pl");
        // `blockTimestamp` and `previousBlockHash` wasn't read from L2 logs
        require(isSystemContextLogProcessed, "by");

        // Making sure that the system contract upgrade was included if needed
        require(_expectedSystemContractUpgradeTxHash == bytes32(0), "bw");
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
        require(
            chainStorage.storedBlockHashes[chainStorage.totalBlocksCommitted] ==
                _hashStoredBlockInfo(_lastCommittedBlockData),
            "i"
        ); // incorrect previous block data
        require(_newBlocksData.length > 0, "No blocks to commit");

        bytes32 systemContractsUpgradeTxHash = chainStorage.l2SystemContractsUpgradeTxHash;
        // Upgrades are rarely done so we optimize a case with no active system contracts upgrade.
        if (systemContractsUpgradeTxHash == bytes32(0) || chainStorage.l2SystemContractsUpgradeBlockNumber != 0) {
            _commitBlocksWithoutSystemContractsUpgrade(_lastCommittedBlockData, _newBlocksData);
        } else {
            _commitBlocksWithSystemContractsUpgrade(
                _lastCommittedBlockData,
                _newBlocksData,
                systemContractsUpgradeTxHash
            );
        }

        chainStorage.totalBlocksCommitted = chainStorage.totalBlocksCommitted + _newBlocksData.length;
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

            chainStorage.storedBlockHashes[_lastCommittedBlockData.blockNumber] = _hashStoredBlockInfo(
                _lastCommittedBlockData
            );
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

        // While the logic of the contract ensures that the chainStorage.l2SystemContractsUpgradeBlockNumber is 0 when this function is called,
        // this check is added just in case. Since it is a hot read, it does not encure noticable gas cost.
        require(chainStorage.l2SystemContractsUpgradeBlockNumber == 0, "ik");

        // Save the block number where the upgrade transaction was executed.
        chainStorage.l2SystemContractsUpgradeBlockNumber = _newBlocksData[0].blockNumber;

        for (uint256 i = 0; i < _newBlocksData.length; i = i.uncheckedInc()) {
            // The upgrade transaction must only be included in the first block.
            bytes32 expectedUpgradeTxHash = i == 0 ? _systemContractUpgradeTxHash : bytes32(0);
            _lastCommittedBlockData = _commitOneBlock(
                _lastCommittedBlockData,
                _newBlocksData[i],
                expectedUpgradeTxHash
            );

            chainStorage.storedBlockHashes[_lastCommittedBlockData.blockNumber] = _hashStoredBlockInfo(
                _lastCommittedBlockData
            );
            emit BlockCommit(
                _lastCommittedBlockData.blockNumber,
                _lastCommittedBlockData.blockHash,
                _lastCommittedBlockData.commitment
            );
        }
    }

    // /// @dev Pops the priority operations from the priority queue and returns a rolling hash of operations
    // function _collectOperationsFromPriorityQueue(uint256 _nPriorityOps) internal returns (bytes32 concatHash) {
    //     concatHash = EMPTY_STRING_KECCAK;

    //     for (uint256 i = 0; i < _nPriorityOps; i = i.uncheckedInc()) {
    //         PriorityOperation memory priorityOp = chainStorage.priorityQueue.popFront();
    //         concatHash = keccak256(abi.encode(concatHash, priorityOp.canonicalTxHash));
    //     }
    // }

    /// @dev Executes one block
    /// @dev 1. Processes all pending operations (Complete priority requests)
    /// @dev 2. Finalizes block on Ethereum
    /// @dev _executedBlockIdx is an index in the array of the blocks that we want to execute together
    function _executeOneBlock(StoredBlockInfo memory _storedBlock, uint256 _executedBlockIdx) internal {
        uint256 currentBlockNumber = _storedBlock.blockNumber;
        require(currentBlockNumber == chainStorage.totalBlocksExecuted + _executedBlockIdx + 1, "k"); // Execute blocks in order
        require(
            _hashStoredBlockInfo(_storedBlock) == chainStorage.storedBlockHashes[currentBlockNumber],
            "exe10" // executing block should be committed
        );

        bytes32 priorityOperationsHash = IBridgeheadChain(chainStorage.bridgeheadChainContract)
            .collectOperationsFromPriorityQueue(_storedBlock.numberOfLayer1Txs);
        require(priorityOperationsHash == _storedBlock.priorityOperationsHash, "x"); // priority operations hash does not match to expected

        // Save root hash of L2 -> L1 logs tree
        IBridgeheadChain(chainStorage.bridgeheadChainContract).addL2Logs(
            currentBlockNumber,
            _storedBlock.l2LogsTreeRoot
        );
    }

    /// @notice Execute blocks, complete priority operations and process withdrawalchainStorage.
    /// @notice 1. Processes all pending operations (Complete priority requests)
    /// @notice 2. Finalizes block on Ethereum
    function executeBlocks(StoredBlockInfo[] calldata _blocksData) external nonReentrant onlyValidator {
        uint256 nBlocks = _blocksData.length;
        for (uint256 i = 0; i < nBlocks; i = i.uncheckedInc()) {
            _executeOneBlock(_blocksData[i], i);
            emit BlockExecution(_blocksData[i].blockNumber, _blocksData[i].blockHash, _blocksData[i].commitment);
        }

        uint256 newTotalBlocksExecuted = chainStorage.totalBlocksExecuted + nBlocks;
        chainStorage.totalBlocksExecuted = newTotalBlocksExecuted;
        require(newTotalBlocksExecuted <= chainStorage.totalBlocksVerified, "n"); // Can't execute blocks more than committed and proven currently.
        require(IBridgeheadChain(chainStorage.bridgeheadChainContract).getFirstUnprocessedPriorityTx() != 0, "n2"); // Checking that chainId update is executed. KL todo, put this in priority queue checks

        uint256 blockWhenUpgradeHappened = chainStorage.l2SystemContractsUpgradeBlockNumber;
        if (blockWhenUpgradeHappened != 0 && blockWhenUpgradeHappened <= newTotalBlocksExecuted) {
            delete chainStorage.l2SystemContractsUpgradeTxHash;
            delete chainStorage.l2SystemContractsUpgradeBlockNumber;
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
        uint256 currentTotalBlocksVerified = chainStorage.totalBlocksVerified;
        uint256 committedBlocksLength = _committedBlocks.length;

        // Save the variable from the storage to memory to save gas
        VerifierParams memory verifierParams = chainStorage.verifierParams;

        // Initialize the array, that will be used as public input to the ZKP
        uint256[] memory proofPublicInput = new uint256[](committedBlocksLength);

        // Check that the block passed by the validator is indeed the first unverified block
        require(_hashStoredBlockInfo(_prevBlock) == chainStorage.storedBlockHashes[currentTotalBlocksVerified], "t1");

        bytes32 prevBlockCommitment = _prevBlock.commitment;
        for (uint256 i = 0; i < committedBlocksLength; i = i.uncheckedInc()) {
            currentTotalBlocksVerified = currentTotalBlocksVerified.uncheckedInc();
            require(
                _hashStoredBlockInfo(_committedBlocks[i]) == chainStorage.storedBlockHashes[currentTotalBlocksVerified],
                "o1"
            );

            bytes32 currentBlockCommitment = _committedBlocks[i].commitment;
            proofPublicInput[i] = _getBlockProofPublicInput(
                prevBlockCommitment,
                currentBlockCommitment,
                _proof,
                verifierParams
            );

            prevBlockCommitment = currentBlockCommitment;
        }
        require(currentTotalBlocksVerified <= chainStorage.totalBlocksCommitted, "q");

        // #if DUMMY_VERIFIER

        // Additional level of protection for the mainnet
        assert(block.chainid != 1);
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.serializedProof.length > 0) {
            bool successVerifyProof = chainStorage.verifier.verify(
                proofPublicInput,
                _proof.serializedProof,
                _proof.recursiveAggregationInput
            );
            require(successVerifyProof, "p"); // Proof verification fail
        }
        // #else
        bool successVerifyProof = chainStorage.verifier.verify(
            proofPublicInput,
            _proof.serializedProof,
            _proof.recursiveAggregationInput
        );
        require(successVerifyProof, "p"); // Proof verification fail
        // #endif

        emit BlocksVerification(chainStorage.totalBlocksVerified, currentTotalBlocksVerified);
        chainStorage.totalBlocksVerified = currentTotalBlocksVerified;
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
                        _verifierParams.recursionLeafLevelVkHash,
                        _verifierParams.recursionCircuitsSetVksHash,
                        _proof.recursiveAggregationInput
                    )
                )
            ) & INPUT_MASK;
    }

    /// @notice Reverts unexecuted blocks
    /// @param _newLastBlock block number after which blocks should be reverted
    /// NOTE: Doesn't delete the stored data about blocks, but only decreases
    /// counters that are responsible for the number of blocks
    function revertBlocks(uint256 _newLastBlock) external nonReentrant onlyValidator {
        require(chainStorage.totalBlocksCommitted > _newLastBlock, "v1"); // The last committed block is less than new last block
        uint256 newTotalBlocksCommitted = _maxU256(_newLastBlock, chainStorage.totalBlocksExecuted);

        if (newTotalBlocksCommitted < chainStorage.totalBlocksVerified) {
            chainStorage.totalBlocksVerified = newTotalBlocksCommitted;
        }
        chainStorage.totalBlocksCommitted = newTotalBlocksCommitted;

        // Reset the block number of the executed system contracts upgrade transaction if the block
        // where the system contracts upgrade was committed is among the reverted blocks.
        if (chainStorage.l2SystemContractsUpgradeBlockNumber > newTotalBlocksCommitted) {
            delete chainStorage.l2SystemContractsUpgradeBlockNumber;
        }

        emit BlocksRevert(
            chainStorage.totalBlocksCommitted,
            chainStorage.totalBlocksVerified,
            chainStorage.totalBlocksExecuted
        );
    }

    /// @notice Returns larger of two values
    function _maxU256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? b : a;
    }

    /// @dev Creates block commitment from its data
    function _createBlockCommitment(CommitBlockInfo calldata _newBlockData) internal view returns (bytes32) {
        bytes32 passThroughDataHash = keccak256(_blockPassThroughData(_newBlockData));
        bytes32 metadataHash = keccak256(_blockMetaParameters());
        bytes32 auxiliaryOutputHash = keccak256(_blockAuxiliaryOutput(_newBlockData));

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
        return
            abi.encodePacked(
                chainStorage.zkPorterIsAvailable,
                chainStorage.l2BootloaderBytecodeHash,
                chainStorage.l2DefaultAccountBytecodeHash
            );
    }

    function _blockAuxiliaryOutput(CommitBlockInfo calldata _block) internal pure returns (bytes memory) {
        require(_block.initialStorageChanges.length <= MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES, "pf");
        require(_block.repeatedStorageChanges.length <= MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES, "py");
        require(_block.l2Logs.length <= MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES, "pu");

        bytes32 initialStorageChangesHash = keccak256(_block.initialStorageChanges);
        bytes32 repeatedStorageChangesHash = keccak256(_block.repeatedStorageChanges);
        bytes32 l2ToL1LogsHash = keccak256(_block.l2Logs);

        return abi.encode(_block.l2LogsTreeRoot, l2ToL1LogsHash, initialStorageChangesHash, repeatedStorageChangesHash);
    }

    /// @notice Returns the keccak hash of the ABI-encoded StoredBlockInfo
    function _hashStoredBlockInfo(StoredBlockInfo memory _storedBlockInfo) internal pure returns (bytes32) {
        return keccak256(abi.encode(_storedBlockInfo));
    }
}
