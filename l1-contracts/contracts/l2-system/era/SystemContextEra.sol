// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContextBase} from "../SystemContextBase.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {ISystemContextDeprecated} from "system-contracts/contracts/interfaces/ISystemContextDeprecated.sol";
import {SystemLogKey, HARD_CODED_CHAIN_ID} from "system-contracts/contracts/Constants.sol";
import {
    CannotInitializeFirstVirtualBlock,
    CannotReuseL2BlockNumberFromPreviousBatch,
    CurrentBatchNumberMustBeGreaterThanZero,
    DeprecatedFunction,
    InconsistentNewBatchTimestamp,
    IncorrectL2BlockHash,
    IncorrectSameL2BlockPrevBlockHash,
    IncorrectSameL2BlockTimestamp,
    IncorrectVirtualBlockInsideMiniblock,
    InvalidNewL2BlockNumber,
    L2BlockAndBatchTimestampMismatch,
    L2BlockNumberZero,
    NoVirtualBlocks,
    NonMonotonicL2BlockTimestamp,
    PreviousL2BlockHashIsIncorrect,
    ProvidedBatchNumberIsNotCorrect,
    TimestampsShouldBeIncremental,
    UpgradeTransactionMustBeFirst
} from "system-contracts/contracts/SystemContractErrors.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Era-specific SystemContext contract. Contains all Era block/batch management logic.
 * @dev Inherits SystemContextBase which preserves the original storage layout for backward compatibility.
 */
contract SystemContextEra is SystemContextBase, ISystemContextDeprecated {
    // ─── Mutating functions (bootloader-only) ───────────────────────────────────

    /// @notice Set the chainId origin.
    /// @param _newChainId The chainId
    function setChainId(uint256 _newChainId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        chainId = _newChainId;
    }

    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        /// Before the genesis upgrade is processed, the block.chainid is wrong. So we skip the setting of the settlement layer chain id.
        /// We set it again after the genesis upgrade is processed.
        if (currentSettlementLayerChainId != _newSettlementLayerChainId && block.chainid != HARD_CODED_CHAIN_ID) {
            IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(
                currentSettlementLayerChainId,
                _newSettlementLayerChainId
            );
            currentSettlementLayerChainId = _newSettlementLayerChainId;
        }
    }

    /// @notice Set the current tx origin.
    /// @param _newOrigin The new tx origin.
    function setTxOrigin(address _newOrigin) external onlyBootloader {
        origin = _newOrigin;
    }

    /// @notice Set the the current gas price.
    /// @param _gasPrice The new tx gasPrice.
    function setGasPrice(uint256 _gasPrice) external onlyBootloader {
        gasPrice = _gasPrice;
    }

    /// @notice Sets the number of L2 gas that is needed to pay a single byte of pubdata.
    /// @dev This value does not have any impact on the execution and purely serves as a way for users
    /// to access the current gas price for the pubdata.
    /// @param _gasPerPubdataByte The amount L2 gas that the operator charge the user for single byte of pubdata.
    /// @param _basePubdataSpent The number of pubdata spent as of the start of the transaction.
    function setPubdataInfo(uint256 _gasPerPubdataByte, uint256 _basePubdataSpent) external onlyBootloader {
        basePubdataSpent = _basePubdataSpent;
        gasPerPubdataByte = _gasPerPubdataByte;
    }

    function getCurrentPubdataSpent() public view returns (uint256) {
        uint256 pubdataPublished = _getPubdataPublished();
        return pubdataPublished > basePubdataSpent ? pubdataPublished - basePubdataSpent : 0;
    }

    function getCurrentPubdataCost() external view returns (uint256) {
        return gasPerPubdataByte * getCurrentPubdataSpent();
    }

    /// @notice Sets the current block number and timestamp of the L2 block.
    /// @dev Called by the bootloader before each transaction. This is needed to ensure
    /// that the data about the block is consistent with the sequencer.
    /// @dev If the new block number is the same as the current one, we ensure that the block's data is
    /// consistent with the one in the current block.
    /// @dev If the new block number is greater than the current one by 1,
    /// then we ensure that timestamp has increased.
    /// @dev If the currently stored number is 0, we assume that it is the first upgrade transaction
    /// and so we will fill up the old data.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _l2BlockTimestamp The timestamp of the new L2 block.
    /// @param _expectedPrevL2BlockHash The expected hash of the previous L2 block.
    /// @param _isFirstInBatch Whether this method is called for the first time in the batch.
    /// @param _maxVirtualBlocksToCreate The maximum number of virtual block to create with this L2 block.
    /// @dev It is a strict requirement that a new virtual block is created at the start of the batch.
    /// @dev It is also enforced that the number of the current virtual L2 block can not exceed the number of the L2 block.
    function setL2Block(
        uint128 _l2BlockNumber,
        uint128 _l2BlockTimestamp,
        bytes32 _expectedPrevL2BlockHash,
        bool _isFirstInBatch,
        uint128 _maxVirtualBlocksToCreate
    ) external onlyBootloader {
        // We check that the timestamp of the L2 block is consistent with the timestamp of the batch.
        if (_isFirstInBatch) {
            uint128 currentBatchTimestamp = currentBatchInfo.timestamp;
            if (_l2BlockTimestamp < currentBatchTimestamp) {
                revert L2BlockAndBatchTimestampMismatch(_l2BlockTimestamp, currentBatchTimestamp);
            }
            if (_maxVirtualBlocksToCreate == 0) {
                revert NoVirtualBlocks();
            }
        }

        (uint128 currentL2BlockNumber, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        if (currentL2BlockNumber == 0 && currentL2BlockTimestamp == 0) {
            // Since currentL2BlockNumber and currentL2BlockTimestamp are zero it means that it is
            // the first ever batch with L2 blocks, so we need to initialize those.
            _upgradeL2Blocks(_l2BlockNumber, _expectedPrevL2BlockHash, _isFirstInBatch);

            _setNewL2BlockData(_l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else if (currentL2BlockNumber == _l2BlockNumber) {
            if (_isFirstInBatch) {
                revert CannotReuseL2BlockNumberFromPreviousBatch();
            }
            if (currentL2BlockTimestamp != _l2BlockTimestamp) {
                revert IncorrectSameL2BlockTimestamp(_l2BlockTimestamp, currentL2BlockTimestamp);
            }
            if (_expectedPrevL2BlockHash != _getLatest257L2blockHash(_l2BlockNumber - 1)) {
                revert IncorrectSameL2BlockPrevBlockHash(
                    _expectedPrevL2BlockHash,
                    _getLatest257L2blockHash(_l2BlockNumber - 1)
                );
            }
            if (_maxVirtualBlocksToCreate != 0) {
                revert IncorrectVirtualBlockInsideMiniblock();
            }
        } else if (currentL2BlockNumber + 1 == _l2BlockNumber) {
            // From the checks in _upgradeL2Blocks it is known that currentL2BlockNumber can not be 0
            bytes32 prevL2BlockHash = _getLatest257L2blockHash(currentL2BlockNumber - 1);

            bytes32 pendingL2BlockHash = _calculateL2BlockHash(
                currentL2BlockNumber,
                currentL2BlockTimestamp,
                prevL2BlockHash,
                currentL2BlockTxsRollingHash
            );

            if (_expectedPrevL2BlockHash != pendingL2BlockHash) {
                revert IncorrectL2BlockHash(_expectedPrevL2BlockHash, pendingL2BlockHash);
            }
            if (_l2BlockTimestamp < currentL2BlockTimestamp) {
                revert NonMonotonicL2BlockTimestamp(_l2BlockTimestamp, currentL2BlockTimestamp);
            }

            // Since the new block is created, we'll clear out the rolling hash
            _setNewL2BlockData(_l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else {
            revert InvalidNewL2BlockNumber(_l2BlockNumber);
        }

        _setVirtualBlock(_l2BlockNumber, _maxVirtualBlocksToCreate, _l2BlockTimestamp);
    }

    /// @notice Appends the transaction hash to the rolling hash of the current L2 block.
    /// @param _txHash The hash of the transaction.
    function appendTransactionToCurrentL2Block(bytes32 _txHash) external onlyBootloader {
        currentL2BlockTxsRollingHash = keccak256(abi.encode(currentL2BlockTxsRollingHash, _txHash));
    }

    /// @notice Publishes L2->L1 logs needed to verify the validity of this batch on L1.
    /// @dev Should be called at the end of the current batch.
    function publishTimestampDataToL1() external onlyBootloader {
        (uint128 currentBatchNumber, uint128 currentBatchTimestamp) = _getBatchNumberAndTimestamp();
        (, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        // The structure of the "setNewBatch" implies that currentBatchNumber > 0, but we still double check it
        if (currentBatchNumber == 0) {
            revert CurrentBatchNumberMustBeGreaterThanZero();
        }

        // In order to spend less pubdata, the packed version is published
        uint256 packedTimestamps = (uint256(currentBatchTimestamp) << 128) | currentL2BlockTimestamp;

        _toL1(false, bytes32(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)), bytes32(packedTimestamps));
    }

    /// @notice Increments the current batch number and sets the new timestamp
    /// @dev Called by the bootloader at the start of the batch.
    /// @param _prevBatchHash The hash of the previous batch.
    /// @param _newTimestamp The timestamp of the new batch.
    /// @param _expectedNewNumber The new batch's number.
    /// @param _baseFee The new batch's base fee
    /// @dev While _expectedNewNumber can be derived as prevBatchNumber + 1, we still
    /// manually supply it here for consistency checks.
    /// @dev The correctness of the _prevBatchHash and _newTimestamp should be enforced on L1.
    function setNewBatch(
        bytes32 _prevBatchHash,
        uint128 _newTimestamp,
        uint128 _expectedNewNumber,
        uint256 _baseFee
    ) external onlyBootloader {
        (uint128 previousBatchNumber, uint128 previousBatchTimestamp) = _getBatchNumberAndTimestamp();
        if (_newTimestamp <= previousBatchTimestamp) {
            revert TimestampsShouldBeIncremental(_newTimestamp, previousBatchTimestamp);
        }
        if (previousBatchNumber + 1 != _expectedNewNumber) {
            revert ProvidedBatchNumberIsNotCorrect(previousBatchNumber + 1, _expectedNewNumber);
        }

        _ensureBatchConsistentWithL2Block(_newTimestamp);

        batchHashes[previousBatchNumber] = _prevBatchHash;

        // Setting new block number and timestamp
        currentBatchInfo = ISystemContext.BlockInfo({number: previousBatchNumber + 1, timestamp: _newTimestamp});

        baseFee = _baseFee;

        // The correctness of this block hash:
        _toL1(false, bytes32(uint256(SystemLogKey.PREV_BATCH_HASH_KEY)), _prevBatchHash);
    }

    /// @notice A testing method that manually sets the current blocks' number and timestamp.
    /// @dev Should be used only for testing / ethCalls and should never be used in production.
    function unsafeOverrideBatch(uint256 _newTimestamp, uint256 _number, uint256 _baseFee) external onlyBootloader {
        currentBatchInfo = ISystemContext.BlockInfo({number: uint128(_number), timestamp: uint128(_newTimestamp)});

        baseFee = _baseFee;
    }

    function incrementTxNumberInBatch() external onlyBootloader {
        ++txNumberInBlock;
    }

    function resetTxNumberInBatch() external onlyBootloader {
        txNumberInBlock = 0;
    }

    // ─── Internal helpers ───────────────────────────────────────────────────────

    /// @notice Returns the current batch's number and timestamp.
    /// @return batchNumber and batchTimestamp tuple of the current batch's number and the current batch's timestamp
    function _getBatchNumberAndTimestamp() internal view returns (uint128 batchNumber, uint128 batchTimestamp) {
        ISystemContext.BlockInfo memory batchInfo = currentBatchInfo;
        batchNumber = batchInfo.number;
        batchTimestamp = batchInfo.timestamp;
    }

    /// @notice Assuming that the block is one of the last MINIBLOCK_HASHES_TO_STORE ones, sets its hash.
    /// @param _block The number of the block.
    /// @param _hash The hash of the block.
    function _setL2BlockHash(uint256 _block, bytes32 _hash) internal {
        l2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE] = _hash;
    }

    /// @notice Calculates the hash of an L2 block.
    /// @param _blockNumber The number of the L2 block.
    /// @param _blockTimestamp The timestamp of the L2 block.
    /// @param _prevL2BlockHash The hash of the previous L2 block.
    /// @param _blockTxsRollingHash The rolling hash of the transactions in the L2 block.
    function _calculateL2BlockHash(
        uint128 _blockNumber,
        uint128 _blockTimestamp,
        bytes32 _prevL2BlockHash,
        bytes32 _blockTxsRollingHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_blockNumber, _blockTimestamp, _prevL2BlockHash, _blockTxsRollingHash));
    }

    /// @notice Calculates the legacy block hash of L2 block, which were used before the upgrade where
    /// the advanced block hashes were introduced.
    /// @param _blockNumber The number of the L2 block.
    function _calculateLegacyL2BlockHash(uint128 _blockNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint32(_blockNumber)));
    }

    /// @notice Performs the upgrade where we transition to the L2 blocks.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _expectedPrevL2BlockHash The expected hash of the previous L2 block.
    /// @param _isFirstInBatch Whether this method is called for the first time in the batch.
    function _upgradeL2Blocks(uint128 _l2BlockNumber, bytes32 _expectedPrevL2BlockHash, bool _isFirstInBatch) internal {
        if (!_isFirstInBatch) {
            revert UpgradeTransactionMustBeFirst();
        }

        // This is how it will be commonly done in practice, but it will simplify some logic later
        if (_l2BlockNumber == 0) {
            revert L2BlockNumberZero();
        }

        unchecked {
            bytes32 correctPrevBlockHash = _calculateLegacyL2BlockHash(_l2BlockNumber - 1);
            if (correctPrevBlockHash != _expectedPrevL2BlockHash) {
                revert PreviousL2BlockHashIsIncorrect(correctPrevBlockHash, _expectedPrevL2BlockHash);
            }

            // Whenever we'll be queried about the hashes of the blocks before the upgrade,
            // we'll use batches' hashes, so we don't need to store 256 previous hashes.
            // However, we do need to store the last previous hash in order to be able to correctly calculate the
            // hash of the new L2 block.
            _setL2BlockHash(_l2BlockNumber - 1, correctPrevBlockHash);
        }
    }

    /// @notice Creates new virtual blocks, while ensuring they don't exceed the L2 block number.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _maxVirtualBlocksToCreate The maximum number of virtual blocks to create with this L2 block.
    /// @param _newTimestamp The timestamp of the new L2 block, which is also the timestamp of the new virtual block.
    function _setVirtualBlock(
        uint128 _l2BlockNumber,
        uint128 _maxVirtualBlocksToCreate,
        uint128 _newTimestamp
    ) internal {
        if (virtualBlockUpgradeInfo.virtualBlockFinishL2Block != 0) {
            // No need to to do anything about virtual blocks anymore
            // All the info is the same as for L2 blocks.
            currentVirtualL2BlockInfo = currentL2BlockInfo;
            return;
        }

        ISystemContext.BlockInfo memory virtualBlockInfo = currentVirtualL2BlockInfo;

        if (currentVirtualL2BlockInfo.number == 0 && virtualBlockInfo.timestamp == 0) {
            uint128 currentBatchNumber = currentBatchInfo.number;

            // The virtual block is set for the first time. We can count it as 1 creation of a virtual block.
            // Note, that when setting the virtual block number we use the batch number to make a smoother upgrade from batch number to
            // the L2 block number.
            virtualBlockInfo.number = currentBatchNumber;
            // Remembering the batch number on which the upgrade to the virtual blocks has been done.
            virtualBlockUpgradeInfo.virtualBlockStartBatch = currentBatchNumber;

            if (_maxVirtualBlocksToCreate == 0) {
                revert CannotInitializeFirstVirtualBlock();
            }
            // solhint-disable-next-line gas-increment-by-one
            _maxVirtualBlocksToCreate -= 1;
        } else if (_maxVirtualBlocksToCreate == 0) {
            // The virtual blocks have been already initialized, but the operator didn't ask to create
            // any new virtual blocks. So we can just return.
            return;
        }

        virtualBlockInfo.number += _maxVirtualBlocksToCreate;
        virtualBlockInfo.timestamp = _newTimestamp;

        // The virtual block number must never exceed the L2 block number.
        // We do not use a `require` here, since the virtual blocks are a temporary solution to let the Solidity's `block.number`
        // catch up with the L2 block number and so the situation where virtualBlockInfo.number starts getting larger
        // than _l2BlockNumber is expected once virtual blocks have caught up the L2 blocks.
        if (virtualBlockInfo.number >= _l2BlockNumber) {
            virtualBlockUpgradeInfo.virtualBlockFinishL2Block = _l2BlockNumber;
            virtualBlockInfo.number = _l2BlockNumber;
        }

        currentVirtualL2BlockInfo = virtualBlockInfo;
    }

    /// @notice Sets the current block number and timestamp of the L2 block.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _l2BlockTimestamp The timestamp of the new L2 block.
    /// @param _prevL2BlockHash The hash of the previous L2 block.
    function _setNewL2BlockData(uint128 _l2BlockNumber, uint128 _l2BlockTimestamp, bytes32 _prevL2BlockHash) internal {
        // In the unsafe version we do not check that the block data is correct
        currentL2BlockInfo = ISystemContext.BlockInfo({number: _l2BlockNumber, timestamp: _l2BlockTimestamp});

        // It is always assumed in production that _l2BlockNumber > 0
        _setL2BlockHash(_l2BlockNumber - 1, _prevL2BlockHash);

        // Resetting the rolling hash
        currentL2BlockTxsRollingHash = bytes32(0);
    }

    /// @notice Ensures that the timestamp of the batch is greater than or equal to the timestamp of the last L2 block.
    /// @param _newTimestamp The timestamp of the new batch.
    function _ensureBatchConsistentWithL2Block(uint128 _newTimestamp) internal view {
        uint128 currentBlockTimestamp = currentL2BlockInfo.timestamp;
        if (_newTimestamp < currentBlockTimestamp) {
            revert InconsistentNewBatchTimestamp(_newTimestamp, currentBlockTimestamp);
        }
    }

    /// @dev Sends an L2-to-L1 log (ZkSync-specific). No-op on standard EVM.
    function _toL1(bool _isService, bytes32 _key, bytes32 _value) internal {
        assembly {
            // TO_L1_CALL_ADDRESS = 0xFFFF on ZkSync
            _isService := and(_isService, 1)
            // solhint-disable-next-line no-unused-vars
            let success := call(_isService, 0xFFFF, _key, _value, 0xFFFF, 0, 0)
        }
    }

    /// @dev Gets pubdata published so far (ZkSync-specific). Returns 0 on standard EVM.
    function _getPubdataPublished() internal view returns (uint32 pubdataPublished) {
        uint256 meta;
        assembly {
            // META_CALL_ADDRESS = 0xFFFC on ZkSync; staticcall returns meta as return value
            meta := staticcall(0, 0xFFFC, 0, 0xFFFF, 0, 0)
        }
        pubdataPublished = uint32(meta);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPRECATED METHODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the hash of the given batch.
    /// @param _batchNumber The number of the batch.
    /// @return hash The hash of the batch.
    /// @dev Deprecated to make publicly accessible methods compatible with planned releases.
    /// @dev Please use the block function `getBlockHashEVM` if needed.
    /// @dev The function will be completely removed in the next release.
    // solhint-disable-next-line no-unused-vars
    function getBatchHash(uint256 _batchNumber) external view returns (bytes32 hash) {
        revert DeprecatedFunction(this.getBatchHash.selector);
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @return batchNumber and batchTimestamp tuple of the current batch's number and the current batch's timestamp
    /// @dev Deprecated for external usage to make publicly accessible methods compatible with planned releases.
    /// @dev Please use the block function `getL2BlockNumberAndTimestamp` if needed.
    /// @dev The function will be completely removed in the next release.
    function getBatchNumberAndTimestamp() external view returns (uint128 batchNumber, uint128 batchTimestamp) {
        revert DeprecatedFunction(this.getBatchNumberAndTimestamp.selector);
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @dev Deprecated for external usage to make publicly accessible methods compatible with planned releases.
    /// @dev Please use the block function `getL2BlockNumberAndTimestamp` if needed.
    /// @dev The function will be completely removed in the next release.
    function currentBlockInfo() external view returns (uint256 blockInfo) {
        revert DeprecatedFunction(this.currentBlockInfo.selector);
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @dev Deprecated to make publicly accessible methods compatible with planned releases.
    /// @dev Please use the block function `getL2BlockNumberAndTimestamp` if needed.
    /// @dev The function will be completely removed in the next release.
    function getBlockNumberAndTimestamp() external view returns (uint256 blockNumber, uint256 blockTimestamp) {
        revert DeprecatedFunction(this.getBlockNumberAndTimestamp.selector);
    }

    /// @notice Returns the hash of the given batch.
    /// @dev Deprecated to make publicly accessible methods compatible with planned releases.
    /// @dev Please use the block function `getBlockHashEVM` if needed.
    /// @dev The function will be completely removed in the next release.
    // solhint-disable-next-line no-unused-vars
    function blockHash(uint256 _blockNumber) external view returns (bytes32 hash) {
        revert DeprecatedFunction(this.blockHash.selector);
    }
}
