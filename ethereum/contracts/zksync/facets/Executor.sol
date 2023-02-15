// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Base.sol";
import "../Config.sol";
import "../interfaces/IExecutor.sol";
import "../libraries/PairingsBn254.sol";
import "../libraries/PriorityQueue.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../../common/libraries/UnsafeBytes.sol";
import "../../common/L2ContractHelper.sol";

/// @title zkSync Executor contract capable of processing events emitted in the zkSync protocol.
/// @author Matter Labs
contract ExecutorFacet is Base, IExecutor {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @dev Process one block commit using the previous block StoredBlockInfo
    /// @dev returns new block StoredBlockInfo
    /// @notice Does not change storage
    function _commitOneBlock(StoredBlockInfo memory _previousBlock, CommitBlockInfo calldata _newBlock)
        internal
        view
        returns (StoredBlockInfo memory)
    {
        require(_newBlock.blockNumber == _previousBlock.blockNumber + 1, "f"); // only commit next block

        // Check that block contain all meta information for L2 logs.
        // Get the chained hash of priority transaction hashes.
        (
            uint256 expectedNumberOfLayer1Txs,
            bytes32 expectedPriorityOperationsHash,
            bytes32 previousBlockHash,
            uint256 l2BlockTimestamp
        ) = _processL2Logs(_newBlock);

        require(_previousBlock.blockHash == previousBlockHash, "l");
        // Check that the priority operation hash in the L2 logs is as expected
        require(expectedPriorityOperationsHash == _newBlock.priorityOperationsHash, "t");
        // Check that the number of processed priority operations is as expected
        require(expectedNumberOfLayer1Txs == _newBlock.numberOfLayer1Txs, "ta");
        // Check that the timestamp that came from the Bootloader is expected
        require(l2BlockTimestamp == _newBlock.timestamp, "tb");

        // Preventing "stack too deep error"
        {
            // Check the timestamp of the new block
            bool timestampNotTooSmall = block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER <= l2BlockTimestamp;
            bool timestampNotTooBig = l2BlockTimestamp <= block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA;
            require(timestampNotTooSmall, "h"); // New block timestamp is too small
            require(timestampNotTooBig, "h1"); // New block timestamp is too big

            // Check the index of repeated storage writes
            uint256 newStorageChangesIndexes = uint256(uint32(bytes4(_newBlock.initialStorageChanges[:4])));
            require(
                _previousBlock.indexRepeatedStorageChanges + newStorageChangesIndexes ==
                    _newBlock.indexRepeatedStorageChanges,
                "yq"
            );

            // NOTE: We don't check that _newBlock.timestamp > _previousBlock.timestamp, it is checked inside the L2
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

    /// @dev Check that L2 logs are proper and block contain all meta information for them
    function _processL2Logs(CommitBlockInfo calldata _newBlock)
        internal
        pure
        returns (
            uint256 numberOfLayer1Txs,
            bytes32 chainedPriorityTxsHash,
            bytes32 previousBlockHash,
            uint256 blockTimestamp
        )
    {
        // Copy L2 to L1 logs into memory.
        bytes memory emittedL2Logs = _newBlock.l2Logs[4:];
        bytes[] calldata l2Messages = _newBlock.l2ArbitraryLengthMessages;
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
            if (logSender == L2_TO_L1_MESSENGER) {
                (bytes32 hashedMessage, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 56);
                require(keccak256(l2Messages[currentMessage]) == hashedMessage, "k2");

                currentMessage = currentMessage.uncheckedInc();
            } else if (logSender == L2_BOOTLOADER_ADDRESS) {
                (bytes32 canonicalTxHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 24);
                chainedPriorityTxsHash = keccak256(abi.encode(chainedPriorityTxsHash, canonicalTxHash));

                // Overflow is not realistic
                numberOfLayer1Txs = numberOfLayer1Txs.uncheckedInc();
            } else if (logSender == L2_SYSTEM_CONTEXT_ADDRESS) {
                // Make sure that the system context log wasn't processed yet, to
                // avoid accident double reading `blockTimestamp` and `previousBlockHash`
                require(!isSystemContextLogProcessed, "fx");
                (blockTimestamp, ) = UnsafeBytes.readUint256(emittedL2Logs, i + 24);
                (previousBlockHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 56);
                // Mark system context log as processed
                isSystemContextLogProcessed = true;
            } else if (logSender == L2_KNOWN_CODE_STORAGE_ADDRESS) {
                (bytes32 bytecodeHash, ) = UnsafeBytes.readBytes32(emittedL2Logs, i + 24);
                require(bytecodeHash == L2ContractHelper.hashL2Bytecode(factoryDeps[currentBytecode]), "k3");

                currentBytecode = currentBytecode.uncheckedInc();
            }
        }
        // To check that only relevant preimages have been included in the calldata
        require(currentBytecode == factoryDeps.length, "ym");
        require(currentMessage == l2Messages.length, "pl");
        // `blockTimestamp` and `previousBlockHash` wasn't read from L2 logs
        require(isSystemContextLogProcessed, "by");
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

        uint256 blocksLength = _newBlocksData.length;
        for (uint256 i = 0; i < blocksLength; i = i.uncheckedInc()) {
            _lastCommittedBlockData = _commitOneBlock(_lastCommittedBlockData, _newBlocksData[i]);
            s.storedBlockHashes[_lastCommittedBlockData.blockNumber] = _hashStoredBlockInfo(_lastCommittedBlockData);

            emit BlockCommit(
                _lastCommittedBlockData.blockNumber,
                _lastCommittedBlockData.blockHash,
                _lastCommittedBlockData.commitment
            );
        }

        s.totalBlocksCommitted = s.totalBlocksCommitted + blocksLength;
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

        s.totalBlocksExecuted = s.totalBlocksExecuted + nBlocks;
        require(s.totalBlocksExecuted <= s.totalBlocksVerified, "n"); // Can't execute blocks more than committed and proven currently.
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
            // TODO: We keep the code duplication here to NOT to invalidate the audit, refactor it before the next audit. (SMA-1631)
            bool successVerifyProof = s.verifier.verify_serialized_proof(proofPublicInput, _proof.serializedProof);
            require(successVerifyProof, "p"); // Proof verification fail

            // Verify the recursive part that was given to us through the public input
            bool successProofAggregation = _verifyRecursivePartOfProof(_proof.recursiveAggregationInput);
            require(successProofAggregation, "hh"); // Proof aggregation must be valid
        }
        // #else
        bool successVerifyProof = s.verifier.verify_serialized_proof(proofPublicInput, _proof.serializedProof);
        require(successVerifyProof, "p"); // Proof verification fail

        // Verify the recursive part that was given to us through the public input
        bool successProofAggregation = _verifyRecursivePartOfProof(_proof.recursiveAggregationInput);
        require(successProofAggregation, "hh"); // Proof aggregation must be valid
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
                        _verifierParams.recursionLeafLevelVkHash,
                        _verifierParams.recursionCircuitsSetVksHash,
                        _proof.recursiveAggregationInput
                    )
                )
            ) & INPUT_MASK;
    }

    /// @dev Verify a part of the zkp, that is responsible for the aggregation
    function _verifyRecursivePartOfProof(uint256[] calldata _recursiveAggregationInput) internal view returns (bool) {
        require(_recursiveAggregationInput.length == 4, "vr");

        PairingsBn254.G1Point memory pairWithGen = PairingsBn254.new_g1_checked(
            _recursiveAggregationInput[0],
            _recursiveAggregationInput[1]
        );
        PairingsBn254.G1Point memory pairWithX = PairingsBn254.new_g1_checked(
            _recursiveAggregationInput[2],
            _recursiveAggregationInput[3]
        );

        PairingsBn254.G2Point memory g2Gen = PairingsBn254.new_g2(
            [
                0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2,
                0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed
            ],
            [
                0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b,
                0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa
            ]
        );
        PairingsBn254.G2Point memory g2X = PairingsBn254.new_g2(
            [
                0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1,
                0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0
            ],
            [
                0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4,
                0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55
            ]
        );

        return PairingsBn254.pairingProd2(pairWithGen, g2Gen, pairWithX, g2X);
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

        emit BlocksRevert(s.totalBlocksCommitted, s.totalBlocksVerified, s.totalBlocksExecuted);
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
        return abi.encodePacked(s.zkPorterIsAvailable, s.l2BootloaderBytecodeHash, s.l2DefaultAccountBytecodeHash);
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
