// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainBase} from "./ZKChainBase.sol";
import {
    COMMIT_TIMESTAMP_APPROXIMATION_DELTA,
    MAINNET_CHAIN_ID,
    MAINNET_COMMIT_TIMESTAMP_NOT_OLDER,
    TESTNET_COMMIT_TIMESTAMP_NOT_OLDER
} from "../../../common/Config.sol";
import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "../../chain-interfaces/IExecutor.sol";
import {ICommitter, CommitBatchInfoZKsyncOS} from "../../chain-interfaces/ICommitter.sol";
import {BatchDecoder} from "../../libraries/BatchDecoder.sol";
import {StoredBatchHashing} from "../StoredBatchHashing.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../../common/l2-helpers/L2ContractInterfaces.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IL1DAValidator, L1DAValidatorOutput} from "../../chain-interfaces/IL1DAValidator.sol";
import {
    BatchNumberMismatch,
    BatchTimestampGreaterThanLastL2BlockTimestamp,
    CanOnlyProcessOneBatch,
    IncorrectBatchChainId,
    InvalidNumberOfBlobs,
    InvalidProtocolVersion,
    L2TimestampTooBig,
    TimeNotReached,
    UpgradeBatchNumberIsNotZero,
    NonZeroBlobToVerifyZKsyncOS,
    InvalidBlockRange,
    InvalidTxCountInPriorityMode
} from "../../../common/L1ContractErrors.sol";
import {MismatchL2DACommitmentScheme, SettlementLayerChainIdMismatch} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @dev The version that is used for the `Executor` calldata used for relaying the
/// ZKSync OS stored batch info.
/// @dev Version 0 was the EraVM relay encoding; the value 1 is kept because relay
/// consumers on the settlement layer distinguish the encodings by this leading byte.
uint8 constant RELAYED_EXECUTOR_VERSION_ZKSYNC_OS = 1;

/// @title ZK chain Committer contract responsible for batch commitment operations.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract CommitterFacet is ZKChainBase, ICommitter {
    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "CommitterFacet";

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

    /// @inheritdoc ICommitter
    function commitBatchesSharedBridge(
        address, // _chainAddress
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) external nonReentrant onlyValidatorOrPriorityMode onlySettlementLayer {
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
        _commitBatchesSharedBridge(_processFrom, _processTo, _commitData);
    }

    function _commitBatchesSharedBridge(uint256 _processFrom, uint256 _processTo, bytes calldata _commitData) internal {
        (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            CommitBatchInfoZKsyncOS[] memory newBatchesData
        ) = BatchDecoder.decodeAndCheckCommitData(_commitData, _processFrom, _processTo);
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
        _commitBatches(lastCommittedBatchData, newBatchesData, processSystemUpgradeTx);

        s.totalBatchesCommitted = s.totalBatchesCommitted + newBatchesData.length;
    }

    function _commitBatches(
        IExecutor.StoredBatchInfo memory _lastCommittedBatchData,
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

        // We disable this check because memory array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _newBatchesData.length; ++i) {
            _lastCommittedBatchData = _commitOneBatch(_lastCommittedBatchData, _newBatchesData[i], upgradeTxHash);

            s.storedBatchHashes[_lastCommittedBatchData.batchNumber] = StoredBatchHashing.hashStoredBatchInfo(
                _lastCommittedBatchData
            );
            emit BlockCommit(
                _lastCommittedBatchData.batchNumber,
                _lastCommittedBatchData.batchHash,
                _lastCommittedBatchData.commitment
            );
            emit ReportCommittedBatchProtocolVersion(
                _lastCommittedBatchData.batchNumber,
                s.protocolVersion,
                upgradeTxHash
            );

            // reset upgradeTxHash after the first batch
            if (i == 0) {
                upgradeTxHash = bytes32(0);
            }
        }
    }

    function _commitOneBatch(
        IExecutor.StoredBatchInfo memory _previousBatch,
        CommitBatchInfoZKsyncOS memory _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash
    ) internal returns (IExecutor.StoredBatchInfo memory storedBatchInfo) {
        // only commit next batch
        if (_newBatch.batchNumber != _previousBatch.batchNumber + 1) {
            revert BatchNumberMismatch(_previousBatch.batchNumber + 1, _newBatch.batchNumber);
        }

        // Preventing stack too deep error
        {
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
                (daOutput.blobsLinearHashes.length != 0 &&
                    daOutput.blobsLinearHashes.length != TOTAL_BLOBS_IN_COMMITMENT)
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
        }

        // When priority mode is activated, the batch must contain only priority transactions
        if (s.priorityModeInfo.activated && (_newBatch.numberOfLayer2Txs != 0 || _newBatch.numberOfLayer1Txs == 0)) {
            revert InvalidTxCountInPriorityMode(_newBatch.numberOfLayer2Txs, _newBatch.numberOfLayer1Txs);
        }

        if (block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER > _newBatch.firstBlockTimestamp) {
            revert TimeNotReached(_newBatch.firstBlockTimestamp, block.timestamp - COMMIT_TIMESTAMP_NOT_OLDER);
        }
        if (_newBatch.lastBlockTimestamp > block.timestamp + COMMIT_TIMESTAMP_APPROXIMATION_DELTA) {
            revert L2TimestampTooBig();
        }
        if (_newBatch.firstBlockTimestamp > _newBatch.lastBlockTimestamp) {
            revert BatchTimestampGreaterThanLastL2BlockTimestamp();
        }
        if (_newBatch.chainId != s.chainId) {
            revert IncorrectBatchChainId(_newBatch.chainId, s.chainId);
        }
        if (_newBatch.daCommitmentScheme != s.l2DACommitmentScheme) {
            revert MismatchL2DACommitmentScheme(uint256(_newBatch.daCommitmentScheme), uint256(s.l2DACommitmentScheme));
        }
        if (_newBatch.slChainId != block.chainid) {
            revert SettlementLayerChainIdMismatch();
        }

        // The batch proof public input can be calculated as
        // keccak256(state_commitment_before & state_commitment_after & chain_config & batch_output_hash),
        // where chain_config is the chain id and the runtime chain config words (see `_getBatchProofPublicInput`).
        // batch output hash commits to information about batch that needs to be opened on l1.
        // So below we are calculating batch output hash to later include it in the batch public input and thereby verify batch values correctness.
        bytes32 batchOutputHash = keccak256(
            abi.encodePacked(
                _newBatch.firstBlockTimestamp,
                _newBatch.lastBlockTimestamp,
                uint256(_newBatch.daCommitmentScheme),
                _newBatch.daCommitment,
                _newBatch.numberOfLayer1Txs,
                _newBatch.numberOfLayer2Txs,
                _newBatch.priorityOperationsHash,
                _newBatch.l2LogsTreeRoot,
                _expectedSystemContractUpgradeTxHash,
                _newBatch.dependencyRootsRollingHash,
                _newBatch.slChainId
            )
        );

        // We are using same stored batch info structure as was used for Era VM state transition.
        // But we set some fields differently:
        // `batchHash` commitments now contains full commitment to the state and `indexRepeatedStorageChanges` not used(always set to 0)
        // `timestamp` is not used anymore(set to 0), for Era we used it to validate that committed batch timestamp is consistent with last stored,
        // but in ZKsync OS we are validating it within the state transition program
        storedBatchInfo = IExecutor.StoredBatchInfo({
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
            // This data includes only `StoredBatchInfo`, which is needed to commit and prove a batch on top
            // of the previous one.
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
}
