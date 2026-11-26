// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "../chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "../chain-interfaces/ICommitter.sol";
import {PubdataContent, ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The ZKsync OS batch commitment: the chain config hash, the batch output hash, the full
/// public-input commitment and the `StoredBatchInfo` a settlement layer stores for a committed batch.
/// Pure functions of their parameters, shared by the `CommitterFacet` and the verify-only batch
/// mirror so both derive the same commitment. See {protocol-docs/chain-config.md#proof-commitment}.
library ZKsyncOSBatchCommitment {
    /// @notice Hashes the runtime configuration a batch was executed with; the layout must match the
    /// ZKsync OS `ChainConfig::hash`.
    /// @param _chainId The chain ID.
    /// @param _maxTxGasLimit The effective single-transaction gas limit (the default already applied).
    /// @param _pubdataContent The pubdata content mode.
    /// @param _l1TxFilteringEnabled Whether L1 transaction filtering is enabled.
    /// @param _largeContractsEnabled Whether large contracts are enabled.
    /// @return The chain config hash.
    function chainConfigHash(
        uint256 _chainId,
        uint64 _maxTxGasLimit,
        PubdataContent _pubdataContent,
        bool _l1TxFilteringEnabled,
        bool _largeContractsEnabled
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _chainId,
                    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED,
                    uint256(_maxTxGasLimit),
                    uint256(_pubdataContent),
                    uint256(_l1TxFilteringEnabled ? 1 : 0),
                    uint256(_largeContractsEnabled ? 1 : 0)
                )
            );
    }

    /// @notice Computes the hash of the batch data opened on the settlement layer. Its layout must
    /// match the ZKsync OS `BatchOutput::hash`.
    /// @param _batch The committed batch.
    /// @param _upgradeTxHash The system upgrade transaction expected in this batch, or zero.
    /// @return The batch output hash.
    function batchOutputHash(
        CommitBatchInfoZKsyncOS memory _batch,
        bytes32 _upgradeTxHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _batch.firstBlockTimestamp,
                    _batch.lastBlockTimestamp,
                    uint256(_batch.daCommitmentScheme),
                    _batch.daCommitment,
                    _batch.numberOfLayer1Txs,
                    _batch.numberOfLayer2Txs,
                    _batch.priorityOperationsHash,
                    _batch.l2LogsTreeRoot,
                    _upgradeTxHash,
                    _batch.dependencyRootsRollingHash,
                    _batch.slChainId,
                    _batch.interopFeeUnits
                )
            );
    }

    /// @notice Computes the full, untruncated batch proof public-input hash.
    /// @param _previousState State commitment before the batch.
    /// @param _newState State commitment after the batch.
    /// @param _chainConfigHash Hash of the runtime configuration used to execute the batch.
    /// @param _batchOutputHash Hash of the batch data opened on the settlement layer.
    /// @return The commitment stored in `StoredBatchInfo` and passed to the verifier.
    function batchCommitment(
        bytes32 _previousState,
        bytes32 _newState,
        bytes32 _chainConfigHash,
        bytes32 _batchOutputHash
    ) internal pure returns (bytes32) {
        // `ZKsyncOSVerifier.computeZKsyncOSHash` applies PUBLIC_INPUT_SHIFT once, after folding the full per-batch hashes.
        return keccak256(abi.encodePacked(_previousState, _newState, _chainConfigHash, _batchOutputHash));
    }

    /// @notice Builds the `StoredBatchInfo` a settlement layer stores for a committed batch.
    /// @dev Commits to `_batch.chainConfigHash` as given: the caller checks it against the chain's
    /// configuration first.
    /// @param _previousState State commitment of the previous batch (its `StoredBatchInfo.batchHash`).
    /// @param _batch The committed batch.
    /// @param _upgradeTxHash The system upgrade transaction expected in this batch, or zero.
    /// @return storedBatchInfo The stored batch info.
    function storedBatchInfo(
        bytes32 _previousState,
        CommitBatchInfoZKsyncOS memory _batch,
        bytes32 _upgradeTxHash
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        // ZKsync OS reuses the Era layout: `batchHash` holds the full state commitment, and
        // `indexRepeatedStorageChanges` and `timestamp` are unused and always zero.
        return
            IExecutor.StoredBatchInfo({
                batchNumber: _batch.batchNumber,
                batchHash: _batch.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _batch.numberOfLayer1Txs,
                priorityOperationsHash: _batch.priorityOperationsHash,
                l2LogsTreeRoot: _batch.l2LogsTreeRoot,
                dependencyRootsRollingHash: _batch.dependencyRootsRollingHash,
                timestamp: 0,
                commitment: batchCommitment(
                    _previousState,
                    _batch.newStateCommitment,
                    _batch.chainConfigHash,
                    batchOutputHash(_batch, _upgradeTxHash)
                )
            });
    }
}
