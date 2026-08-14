// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBase} from "./ZKChainBase.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "../../../core/message-root/IMessageRoot.sol";
import {EMPTY_STRING_KECCAK, PUBLIC_INPUT_SHIFT} from "../../../common/Config.sol";
import {IExecutor} from "../../chain-interfaces/IExecutor.sol";
import {BatchDecoder} from "../../libraries/BatchDecoder.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {PriorityOpsBatchInfo, PriorityTree} from "../../libraries/PriorityTree.sol";
import {
    CanOnlyProcessOneBatch,
    CantExecuteUnprovenBatches,
    InvalidMessageRoot,
    InvalidProof,
    NonSequentialBatch,
    PriorityOperationsRollingHashMismatch,
    VerifiedBatchesExceedsCommittedBatches
} from "../../../common/L1ContractErrors.sol";
import {
    CommitBasedInteropNotSupported,
    DependencyRootsRollingHashMismatch,
    InvalidBatchesDataLength,
    InvalidInteropRootTimestamp,
    MessageRootIsZero,
    MismatchNumberOfLayer1Txs
} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";
import {InteropRoot, StoredInteropRoot} from "../../../common/Messaging.sol";

/// @title ZK chain Executor contract capable of processing events emitted in the ZK chain protocol.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ExecutorFacet is ZKChainBase, IExecutor {
    using UncheckedMath for uint256;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "ExecutorFacet";

    function _rollingHash(bytes32[] memory _hashes) internal pure returns (bytes32) {
        bytes32 hash = EMPTY_STRING_KECCAK;
        uint256 nHashes = _hashes.length;
        for (uint256 i = 0; i < nHashes; ++i) {
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
        IMessageRootBase messageRootContract = IBridgehubBase(s.bridgehub).messageRoot();

        for (uint256 i = 0; i < length; ++i) {
            InteropRoot memory interopRoot = _dependencyRoots[i];
            bytes32 correctRootHash;
            uint256 correctTimestamp;
            if (interopRoot.chainId == block.chainid) {
                // In this release interop roots are imported only from the chain's own settlement
                // layer, so the local MessageRoot record is the only case to cover.
                // See {protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}.
                StoredInteropRoot memory recordedRoot = messageRootContract.historicalRoot(
                    uint256(interopRoot.blockOrBatchNumber)
                );
                correctRootHash = recordedRoot.root;
                correctTimestamp = recordedRoot.timestamp;
            } else {
                revert CommitBasedInteropNotSupported();
            }
            if (correctRootHash == bytes32(0)) {
                revert MessageRootIsZero();
            }
            if (interopRoot.sides.length != 1 || interopRoot.sides[0] != correctRootHash) {
                revert InvalidMessageRoot(correctRootHash, interopRoot.sides[0]);
            }
            if (interopRoot.timestamp != correctTimestamp) {
                revert InvalidInteropRootTimestamp(correctTimestamp, interopRoot.timestamp);
            }
            dependencyRootsRollingHash = keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(
                    dependencyRootsRollingHash,
                    interopRoot.chainId,
                    interopRoot.blockOrBatchNumber,
                    interopRoot.timestamp,
                    interopRoot.sides
                )
            );
        }
    }

    /// @notice Appends the batch's chain batch root to the L1 MessageRoot.
    /// @param _batchNumber The number of the batch
    /// @param _messageRoot The root of the merkle tree of the messages to L1.
    function _appendMessageRoot(uint256 _batchNumber, bytes32 _messageRoot) internal {
        IMessageRootBase messageRootContract = IBridgehubBase(s.bridgehub).messageRoot();
        messageRootContract.addChainBatchRootV32(s.chainId, _batchNumber, _messageRoot);
    }

    /// @inheritdoc IExecutor
    // slither-disable-next-line reentrancy-no-eth
    function executeBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _executeData
    ) external nonReentrant onlyValidatorOrPriorityMode onlySettlementLayer {
        BatchDecoder.DecodedExecuteData memory decoded = BatchDecoder.decodeAndCheckExecuteData(
            _executeData,
            _processFrom,
            _processTo
        );
        StoredBatchInfo[] memory batchesData = decoded.batchesData;
        uint256 nBatches = batchesData.length;
        if (batchesData.length != decoded.priorityOpsData.length) {
            revert InvalidBatchesDataLength(batchesData.length, decoded.priorityOpsData.length);
        }
        if (batchesData.length != decoded.dependencyRoots.length) {
            revert InvalidBatchesDataLength(batchesData.length, decoded.dependencyRoots.length);
        }

        // Cross-chain asset correctness is enforced by the ZK proof, so no per-batch log
        // reconstruction / balance accounting happens here. See {protocol-docs/message-root.md#v31-vs-v32-append-flows}.
        for (uint256 i = 0; i < nBatches; ++i) {
            _appendMessageRoot(batchesData[i].batchNumber, batchesData[i].l2LogsTreeRoot);
        }

        for (uint256 i = 0; i < nBatches; ++i) {
            _executeOneBatch(batchesData[i], decoded.priorityOpsData[i], decoded.dependencyRoots[i], i);
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
        for (uint256 i = 0; i < committedBatchesLength; ++i) {
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

    /// @dev Gets zk proof public input for ZKSync OS.
    function _getBatchProofPublicInputZKsyncOS(
        bytes32 _prevBatchStateCommitment,
        bytes32 _currentBatchStateCommitment,
        bytes32 _currentBatchCommitment
    ) internal view returns (uint256) {
        // `fri_proof_verification_enabled` is always disabled, hence the `0` word.
        // The final word is the pubdata content (`FULL_PUBDATA=0`/`LOGS_ONLY=1`), mirroring `ChainConfig::hash`
        // on ZKsync OS, which appends `pubdata_content` after `max_tx_gas_limit`.
        bytes32 chainConfigHash = keccak256(
            abi.encodePacked(s.chainId, uint256(0), uint256(_getZKsyncOSMaxTxGasLimit()), uint256(s.pubdataContent))
        );
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        _prevBatchStateCommitment,
                        _currentBatchStateCommitment,
                        chainConfigHash,
                        _currentBatchCommitment
                    )
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
    // NOTE: Keep `_revertBatches` execution gas bounded so `activatePriorityMode`
    // cannot be blocked by an unexpectedly expensive revert. A gas cap is enforced
    // in tests via `RevertingTest.test_RevertBatchesGasBound`.
    function revertBatchesSharedBridge(
        address,
        uint256 _newLastBatch
    ) external nonReentrant onlyValidatorOrChainTypeManager notPriorityMode onlySettlementLayer {
        _revertBatches(_newLastBatch);
    }
}
