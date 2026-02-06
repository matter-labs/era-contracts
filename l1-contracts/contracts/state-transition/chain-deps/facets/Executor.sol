// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBase} from "./ZKChainBase.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IMessageRoot} from "../../../core/message-root/IMessageRoot.sol";
import {EMPTY_STRING_KECCAK, PUBLIC_INPUT_SHIFT} from "../../../common/Config.sol";
import {IExecutor, ProcessLogsInput} from "../../chain-interfaces/IExecutor.sol";
import {BatchDecoder} from "../../libraries/BatchDecoder.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {GW_ASSET_TRACKER} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {PriorityOpsBatchInfo, PriorityTree} from "../../libraries/PriorityTree.sol";
import {BatchHashMismatch, CanOnlyProcessOneBatch, CantExecuteUnprovenBatches, InvalidMessageRoot, InvalidProof, NonSequentialBatch, PriorityOperationsRollingHashMismatch, VerifiedBatchesExceedsCommittedBatches} from "../../../common/L1ContractErrors.sol";
import {CommitBasedInteropNotSupported, DependencyRootsRollingHashMismatch, InvalidBatchesDataLength, MessageRootIsZero, MismatchNumberOfLayer1Txs} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";
import {InteropRoot, L2Log} from "../../../common/Messaging.sol";

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

    constructor(uint256 _l1ChainId) {
        L1_CHAIN_ID = _l1ChainId;
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
    // slither-disable-next-line reentrancy-no-eth
    function executeBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external nonReentrant onlyValidatorOrPriorityMode onlySettlementLayer {
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
    ) external nonReentrant onlyValidatorOrPriorityMode onlySettlementLayer {
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
                proofPublicInput[i] =
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                prevBatchStateCommitment,
                                currentBatchStateCommitment,
                                currentBatchCommitment
                            )
                        )
                    ) >>
                    PUBLIC_INPUT_SHIFT;
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

    /// @dev Gets zk proof public input
    function _getBatchProofPublicInput(
        bytes32 _prevBatchCommitment,
        bytes32 _currentBatchCommitment
    ) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(_prevBatchCommitment, _currentBatchCommitment))) >> PUBLIC_INPUT_SHIFT;
    }

    /// @inheritdoc IExecutor
    // NOTE: Keep `_revertBatches` execution gas bounded so `activatePriorityMode`
    // cannot be blocked by an unexpectedly expensive revert. A gas cap is enforced
    // in tests via `RevertingTest.test_RevertBatchesGasBound`.
    function revertBatchesSharedBridge(
        address,
        uint256 _newLastBatch
    ) external nonReentrant onlyValidatorOrChainTypeManager notPriorityMode onlySettlementLayer {
        _revertBatches(_newLastBatch);
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
}
