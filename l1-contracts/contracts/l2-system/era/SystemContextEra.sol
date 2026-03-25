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
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Era-specific SystemContext contract. Contains all Era block/batch management logic.
 * @dev Inherits SystemContextBase which preserves the original storage layout for backward
 * compatibility. All public methods and Era-specific getters live exclusively in this contract.
 */
contract SystemContextEra is SystemContextBase, ISystemContextDeprecated {
    // chainId (slot 0) is inherited as a public state variable from SystemContextBase.

    /// @notice The `tx.origin` in the current transaction.
    function origin() external view returns (address) {
        return _eraOrigin;
    }

    /// @notice The `tx.gasPrice` in the current transaction.
    function gasPrice() external view returns (uint256) {
        return _eraGasPrice;
    }

    /// @notice The current block's gasLimit.
    function blockGasLimit() external view returns (uint256) {
        return _eraBlockGasLimit;
    }

    /// @notice The `block.coinbase` in the current transaction.
    function coinbase() external view returns (address) {
        return _eraCoinbase;
    }

    /// @notice Formal `block.difficulty` parameter.
    function difficulty() external view returns (uint256) {
        return _eraDifficulty;
    }

    /// @notice The `block.basefee`.
    function baseFee() external view returns (uint256) {
        return _eraBaseFee;
    }

    // currentSettlementLayerChainId (slot 270) is inherited as a public state variable from SystemContextBase.

    /// @notice Set the chainId origin.
    /// @param _newChainId The chainId
    function setChainId(uint256 _newChainId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        chainId = _newChainId;
    }

    /// @notice Updates the settlement layer chain ID.
    /// @dev On the original hard-coded Era chain (block.chainid == HARD_CODED_CHAIN_ID) the
    /// genesis upgrade is processed before the chain ID is properly set, so we skip the update
    /// to avoid calling the chain asset handler with a wrong chain ID.
    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        if (block.chainid == HARD_CODED_CHAIN_ID) {
            return;
        }
        _setSettlementLayerChainId(_newSettlementLayerChainId);
    }

    /// @notice Number of current transaction in block.
    function txNumberInBlock() external view returns (uint16) {
        return _eraTxNumberInBlock;
    }

    /// @notice The current gas per pubdata byte.
    function gasPerPubdataByte() external view returns (uint256) {
        return _eraGasPerPubdataByte;
    }

    /// @notice Set the current tx origin.
    /// @param _newOrigin The new tx origin.
    function setTxOrigin(address _newOrigin) external onlyBootloader {
        _eraOrigin = _newOrigin;
    }

    /// @notice Set the the current gas price.
    /// @param _gasPrice The new tx gasPrice.
    function setGasPrice(uint256 _gasPrice) external onlyBootloader {
        _eraGasPrice = _gasPrice;
    }

    /// @notice Sets the number of L2 gas that is needed to pay a single byte of pubdata.
    /// @dev This value does not have any impact on the execution and purely serves as a way for users
    /// to access the current gas price for the pubdata.
    /// @param _gasPerPubdataByte The amount L2 gas that the operator charge the user for single byte of pubdata.
    /// @param _basePubdataSpent The number of pubdata spent as of the start of the transaction.
    function setPubdataInfo(uint256 _gasPerPubdataByte, uint256 _basePubdataSpent) external onlyBootloader {
        _eraBasePubdataSpent = _basePubdataSpent;
        _eraGasPerPubdataByte = _gasPerPubdataByte;
    }

    function getCurrentPubdataSpent() public view returns (uint256) {
        uint256 pubdataPublished = _getPubdataPublished();
        return pubdataPublished > _eraBasePubdataSpent ? pubdataPublished - _eraBasePubdataSpent : 0;
    }

    function getCurrentPubdataCost() external view returns (uint256) {
        return _eraGasPerPubdataByte * getCurrentPubdataSpent();
    }

    /// @notice The method that emulates `blockhash` opcode in EVM.
    /// @dev Just like the blockhash in the EVM, it returns bytes32(0),
    /// when queried about hashes that are older than 256 blocks ago.
    /// @dev Since zksolc compiler calls this method to emulate `blockhash`,
    /// its signature can not be changed to `getL2BlockHashEVM`.
    /// @return hash The blockhash of the block with the given number.
    function getBlockHashEVM(uint256 _block) external view returns (bytes32 hash) {
        uint128 blockNumber = _eraCurrentVirtualL2BlockInfo.number;

        ISystemContext.VirtualBlockUpgradeInfo memory currentVirtualBlockUpgradeInfo = _eraVirtualBlockUpgradeInfo;

        // Due to virtual blocks upgrade, we'll have to use the following logic for retrieving the blockhash:
        // 1. If the block number is out of the 256-block supported range, return 0.
        // 2. If the block was created before the upgrade for the virtual blocks (i.e. there we used to use hashes of the batches),
        // we return the hash of the batch.
        // 3. If the block was created after the day when the virtual blocks have caught up with the L2 blocks, i.e.
        // all the information which is returned for users should be for L2 blocks, we return the hash of the corresponding L2 block.
        // 4. If the block queried is a virtual blocks, calculate it on the fly.
        if (blockNumber <= _block || blockNumber - _block > 256) {
            hash = bytes32(0);
        } else if (_block < currentVirtualBlockUpgradeInfo.virtualBlockStartBatch) {
            // Note, that we will get into this branch only for a brief moment of time, right after the upgrade
            // for virtual blocks before 256 virtual blocks are produced.
            hash = _eraBatchHashes[_block];
        } else if (
            _block >= currentVirtualBlockUpgradeInfo.virtualBlockFinishL2Block &&
            currentVirtualBlockUpgradeInfo.virtualBlockFinishL2Block > 0
        ) {
            hash = _getLatest257L2blockHash(_block);
        } else {
            // Important: we do not want this number to ever collide with the L2 block hash (either new or old one) and so
            // that's why the legacy L2 blocks' hashes are keccak256(abi.encodePacked(uint32(_block))), while these are equivalent to
            // keccak256(abi.encodePacked(_block))
            hash = keccak256(abi.encode(_block));
        }
    }

    /// @notice Returns the current block's number and timestamp.
    /// @return blockNumber and blockTimestamp tuple of the current L2 block's number and the current block's timestamp
    function getL2BlockNumberAndTimestamp() public view returns (uint128 blockNumber, uint128 blockTimestamp) {
        ISystemContext.BlockInfo memory blockInfo = _eraCurrentL2BlockInfo;
        blockNumber = blockInfo.number;
        blockTimestamp = blockInfo.timestamp;
    }

    /// @notice Returns the current L2 block's number.
    /// @dev Since zksolc compiler calls this method to emulate `block.number`,
    /// its signature can not be changed to `getL2BlockNumber`.
    /// @return blockNumber The current L2 block's number.
    function getBlockNumber() public view returns (uint128) {
        return _eraCurrentVirtualL2BlockInfo.number;
    }

    /// @notice Returns the current L2 block's timestamp.
    /// @dev Since zksolc compiler calls this method to emulate `block.timestamp`,
    /// its signature can not be changed to `getL2BlockTimestamp`.
    /// @return timestamp The current L2 block's timestamp.
    function getBlockTimestamp() public view returns (uint128) {
        return _eraCurrentVirtualL2BlockInfo.timestamp;
    }

    /// @notice Assuming that block is one of the last MINIBLOCK_HASHES_TO_STORE ones, returns its hash.
    /// @param _block The number of the block.
    /// @return hash The hash of the block.
    function _getLatest257L2blockHash(uint256 _block) internal view returns (bytes32) {
        return _eraL2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE];
    }

    /// @notice Assuming that the block is one of the last MINIBLOCK_HASHES_TO_STORE ones, sets its hash.
    /// @param _block The number of the block.
    /// @param _hash The hash of the block.
    function _setL2BlockHash(uint256 _block, bytes32 _hash) internal {
        _eraL2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE] = _hash;
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
        if (_eraVirtualBlockUpgradeInfo.virtualBlockFinishL2Block != 0) {
            // No need to to do anything about virtual blocks anymore
            // All the info is the same as for L2 blocks.
            _eraCurrentVirtualL2BlockInfo = _eraCurrentL2BlockInfo;
            return;
        }

        ISystemContext.BlockInfo memory virtualBlockInfo = _eraCurrentVirtualL2BlockInfo;

        if (_eraCurrentVirtualL2BlockInfo.number == 0 && virtualBlockInfo.timestamp == 0) {
            uint128 currentBatchNumber = _eraCurrentBatchInfo.number;

            // The virtual block is set for the first time. We can count it as 1 creation of a virtual block.
            // Note, that when setting the virtual block number we use the batch number to make a smoother upgrade from batch number to
            // the L2 block number.
            virtualBlockInfo.number = currentBatchNumber;
            // Remembering the batch number on which the upgrade to the virtual blocks has been done.
            _eraVirtualBlockUpgradeInfo.virtualBlockStartBatch = currentBatchNumber;

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
            _eraVirtualBlockUpgradeInfo.virtualBlockFinishL2Block = _l2BlockNumber;
            virtualBlockInfo.number = _l2BlockNumber;
        }

        _eraCurrentVirtualL2BlockInfo = virtualBlockInfo;
    }

    /// @notice Sets the current block number and timestamp of the L2 block.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _l2BlockTimestamp The timestamp of the new L2 block.
    /// @param _prevL2BlockHash The hash of the previous L2 block.
    function _setNewL2BlockData(uint128 _l2BlockNumber, uint128 _l2BlockTimestamp, bytes32 _prevL2BlockHash) internal {
        // In the unsafe version we do not check that the block data is correct
        _eraCurrentL2BlockInfo = ISystemContext.BlockInfo({number: _l2BlockNumber, timestamp: _l2BlockTimestamp});

        // It is always assumed in production that _l2BlockNumber > 0
        _setL2BlockHash(_l2BlockNumber - 1, _prevL2BlockHash);

        // Resetting the rolling hash
        _eraCurrentL2BlockTxsRollingHash = bytes32(0);
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
            uint128 currentBatchTimestamp = _eraCurrentBatchInfo.timestamp;
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
                _eraCurrentL2BlockTxsRollingHash
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
        _eraCurrentL2BlockTxsRollingHash = keccak256(abi.encode(_eraCurrentL2BlockTxsRollingHash, _txHash));
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

    /// @notice Ensures that the timestamp of the batch is greater than or equal to the timestamp of the last L2 block.
    /// @param _newTimestamp The timestamp of the new batch.
    function _ensureBatchConsistentWithL2Block(uint128 _newTimestamp) internal view {
        uint128 currentBlockTimestamp = _eraCurrentL2BlockInfo.timestamp;
        if (_newTimestamp < currentBlockTimestamp) {
            revert InconsistentNewBatchTimestamp(_newTimestamp, currentBlockTimestamp);
        }
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

        _eraBatchHashes[previousBatchNumber] = _prevBatchHash;

        // Setting new block number and timestamp
        _eraCurrentBatchInfo = ISystemContext.BlockInfo({number: previousBatchNumber + 1, timestamp: _newTimestamp});

        _eraBaseFee = _baseFee;

        // The correctness of this block hash:
        _toL1(false, bytes32(uint256(SystemLogKey.PREV_BATCH_HASH_KEY)), _prevBatchHash);
    }

    /// @notice A testing method that manually sets the current blocks' number and timestamp.
    /// @dev Should be used only for testing / ethCalls and should never be used in production.
    function unsafeOverrideBatch(uint256 _newTimestamp, uint256 _number, uint256 _baseFee) external onlyBootloader {
        _eraCurrentBatchInfo = ISystemContext.BlockInfo({number: uint128(_number), timestamp: uint128(_newTimestamp)});

        _eraBaseFee = _baseFee;
    }

    function incrementTxNumberInBatch() external onlyBootloader {
        ++_eraTxNumberInBlock;
    }

    function resetTxNumberInBatch() external onlyBootloader {
        _eraTxNumberInBlock = 0;
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @return batchNumber and batchTimestamp tuple of the current batch's number and the current batch's timestamp
    function _getBatchNumberAndTimestamp() internal view returns (uint128 batchNumber, uint128 batchTimestamp) {
        ISystemContext.BlockInfo memory batchInfo = _eraCurrentBatchInfo;
        batchNumber = batchInfo.number;
        batchTimestamp = batchInfo.timestamp;
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

    /*//////////////////////////////////////////////////////////////
                    ZKSYNC-SPECIFIC ASSEMBLY HELPERS
    //////////////////////////////////////////////////////////////*/

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
}
