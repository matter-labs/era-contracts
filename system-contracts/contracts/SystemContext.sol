// SPDX-License-Identifier: MIT

// solhint-disable reason-string, gas-custom-errors

pragma solidity 0.8.20;

import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {ISystemContextDeprecated} from "./interfaces/ISystemContextDeprecated.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, SystemLogKey} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Contract that stores some of the context variables, that may be either
 * block-scoped, tx-scoped or system-wide.
 */
contract SystemContext is ISystemContext, ISystemContextDeprecated, ISystemContract {
    /// @notice The number of latest L2 blocks to store.
    /// @dev EVM requires us to be able to query the hashes of previous 256 blocks.
    /// We could either:
    /// - Store the latest 256 hashes (and strictly rely that we do not accidentally override the hash of the block 256 blocks ago)
    /// - Store the latest 257 blocks' hashes.
    uint256 internal constant MINIBLOCK_HASHES_TO_STORE = 257;

    /// @notice The chainId of the network. It is set at the genesis.
    uint256 public chainId;

    /// @notice The `tx.origin` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    address public origin;

    /// @notice The `tx.gasPrice` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    uint256 public gasPrice;

    /// @notice The current block's gasLimit.
    /// @dev The same limit is used for both batches and L2 blocks. At this moment this limit is not explicitly
    /// forced by the system, rather it is the responsibility of the operator to ensure that this value is never achieved.
    uint256 public blockGasLimit = (1 << 50);

    /// @notice The `block.coinbase` in the current transaction.
    /// @dev For the support of coinbase, we will use the bootloader formal address for now
    address public coinbase = BOOTLOADER_FORMAL_ADDRESS;

    /// @notice Formal `block.difficulty` parameter.
    uint256 public difficulty = 2.5e15;

    /// @notice The `block.basefee`.
    /// @dev It is currently a constant.
    uint256 public baseFee;

    /// @notice The number and the timestamp of the current L1 batch stored packed.
    BlockInfo internal currentBatchInfo;

    /// @notice The hashes of batches.
    /// @dev It stores batch hashes for all previous batches.
    mapping(uint256 batchNumber => bytes32 batchHash) internal batchHashes;

    /// @notice The number and the timestamp of the current L2 block.
    BlockInfo internal currentL2BlockInfo;

    /// @notice The rolling hash of the transactions in the current L2 block.
    bytes32 internal currentL2BlockTxsRollingHash;

    /// @notice The hashes of L2 blocks.
    /// @dev It stores block hashes for previous L2 blocks. Note, in order to make publishing the hashes
    /// of the miniblocks cheaper, we only store the previous MINIBLOCK_HASHES_TO_STORE ones. Since whenever we need to publish a state
    /// diff, a pair of <key, value> is published and for cached keys only 8-byte id is used instead of 32 bytes.
    /// By having this data in a cyclic array of MINIBLOCK_HASHES_TO_STORE blocks, we bring the costs down by 40% (i.e. 40 bytes per miniblock instead of 64 bytes).
    /// @dev The hash of a miniblock with number N would be stored under slot N%MINIBLOCK_HASHES_TO_STORE.
    /// @dev Hashes of the blocks older than the ones which are stored here can be calculated as _calculateLegacyL2BlockHash(blockNumber).
    bytes32[MINIBLOCK_HASHES_TO_STORE] internal l2BlockHash;

    BlockInfo internal DEPRECATED_currentL2VirtualBlockInfo;
    uint256 internal DEPRECATED_virtualBlockUpgradeInfo;


    /// @notice Set the chainId origin.
    /// @param _newChainId The chainId
    function setChainId(uint256 _newChainId) external onlyCallFromForceDeployer {
        chainId = _newChainId;
    }

    /// @notice Number of current transaction in block.
    uint16 public txNumberInBlock;

    /// @notice The current gas per pubdata byte
    uint256 public gasPerPubdataByte;

    /// @notice The number of pubdata spent as of the start of the transaction
    uint256 internal basePubdataSpent;

    /// @notice Set the current tx origin.
    /// @param _newOrigin The new tx origin.
    function setTxOrigin(address _newOrigin) external onlyCallFromBootloader {
        origin = _newOrigin;
    }

    /// @notice Set the the current gas price.
    /// @param _gasPrice The new tx gasPrice.
    function setGasPrice(uint256 _gasPrice) external onlyCallFromBootloader {
        gasPrice = _gasPrice;
    }

    /// @notice Sets the number of L2 gas that is needed to pay a single byte of pubdata.
    /// @dev This value does not have any impact on the execution and purely serves as a way for users
    /// to access the current gas price for the pubdata.
    /// @param _gasPerPubdataByte The amount L2 gas that the operator charge the user for single byte of pubdata.
    /// @param _basePubdataSpent The number of pubdata spent as of the start of the transaction.
    function setPubdataInfo(uint256 _gasPerPubdataByte, uint256 _basePubdataSpent) external onlyCallFromBootloader {
        basePubdataSpent = _basePubdataSpent;
        gasPerPubdataByte = _gasPerPubdataByte;
    }

    function getCurrentPubdataSpent() public view returns (uint256) {
        uint256 pubdataPublished = SystemContractHelper.getZkSyncMeta().pubdataPublished;
        return pubdataPublished > basePubdataSpent ? pubdataPublished - basePubdataSpent : 0;
    }

    function getCurrentPubdataCost() external view returns (uint256) {
        return gasPerPubdataByte * getCurrentPubdataSpent();
    }

    /// @notice The method that emulates `blockhash` opcode in EVM.
    /// @dev Just like the blockhash in the EVM, it returns bytes32(0),
    /// when queried about hashes that are older than 256 blocks ago.
    /// @dev Since zksolc compiler calls this method to emulate `blockhash`,
    /// its signature can not be changed to `getL2BlockHashEVM`.
    /// @return hash The blockhash of the block with the given number.
    function getBlockHashEVM(uint256 _block) external view returns (bytes32 hash) {
        uint128 blockNumber = currentL2BlockInfo.number;

        // 1. If the block number is out of the 256-block supported range, return 0.
        // 2. If the block was created on genesis - return the hash of the batch.
        // 3. If the block was created after genesis all the information which is returned for users should be for L2 blocks, we return the hash of the corresponding L2 block.

        if (blockNumber <= _block || blockNumber - _block > 256) {
            hash = bytes32(0);
        } else if (_block == 0) {
            // Note, that we will get into this branch only for a brief moment of time, right after the genesis
            hash = batchHashes[_block];
        } else {
            hash = _getLatest257L2blockHash(_block);
        }
    }

    /// @notice Returns the hash of the given batch.
    /// @param _batchNumber The number of the batch.
    /// @return hash The hash of the batch.
    function getBatchHash(uint256 _batchNumber) external view returns (bytes32 hash) {
        hash = batchHashes[_batchNumber];
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @return batchNumber and batchTimestamp tuple of the current batch's number and the current batch's timestamp
    function getBatchNumberAndTimestamp() public view returns (uint128 batchNumber, uint128 batchTimestamp) {
        BlockInfo memory batchInfo = currentBatchInfo;
        batchNumber = batchInfo.number;
        batchTimestamp = batchInfo.timestamp;
    }

    /// @notice Returns the current block's number and timestamp.
    /// @return blockNumber and blockTimestamp tuple of the current L2 block's number and the current block's timestamp
    function getL2BlockNumberAndTimestamp() public view returns (uint128 blockNumber, uint128 blockTimestamp) {
        BlockInfo memory blockInfo = currentL2BlockInfo;
        blockNumber = blockInfo.number;
        blockTimestamp = blockInfo.timestamp;
    }

    /// @notice Returns the current L2 block's number.
    /// @dev Since zksolc compiler calls this method to emulate `block.number`,
    /// its signature can not be changed to `getL2BlockNumber`.
    /// @return blockNumber The current L2 block's number.
    function getBlockNumber() public view returns (uint128) {
        return currentL2BlockInfo.number;
    }

    /// @notice Returns the current L2 block's timestamp.
    /// @dev Since zksolc compiler calls this method to emulate `block.timestamp`,
    /// its signature can not be changed to `getL2BlockTimestamp`.
    /// @return timestamp The current L2 block's timestamp.
    function getBlockTimestamp() public view returns (uint128) {
        return currentL2BlockInfo.timestamp;
    }

    /// @notice Assuming that block is one of the last MINIBLOCK_HASHES_TO_STORE ones, returns its hash.
    /// @param _block The number of the block.
    /// @return hash The hash of the block.
    function _getLatest257L2blockHash(uint256 _block) internal view returns (bytes32) {
        return l2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE];
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
        require(_isFirstInBatch, "Upgrade transaction must be first");

        // This is how it will be commonly done in practice, but it will simplify some logic later
        require(_l2BlockNumber > 0, "L2 block number is never expected to be zero");

        unchecked {
            bytes32 correctPrevBlockHash = _calculateLegacyL2BlockHash(_l2BlockNumber - 1);
            require(correctPrevBlockHash == _expectedPrevL2BlockHash, "The previous L2 block hash is incorrect");

            // Whenever we'll be queried about the hashes of the blocks before the upgrade,
            // we'll use batches' hashes, so we don't need to store 256 previous hashes.
            // However, we do need to store the last previous hash in order to be able to correctly calculate the
            // hash of the new L2 block.
            _setL2BlockHash(_l2BlockNumber - 1, correctPrevBlockHash);
        }
    }

    /// @notice Sets the current block number and timestamp of the L2 block.
    /// @param _l2BlockNumber The number of the new L2 block.
    /// @param _l2BlockTimestamp The timestamp of the new L2 block.
    /// @param _prevL2BlockHash The hash of the previous L2 block.
    function _setNewL2BlockData(uint128 _l2BlockNumber, uint128 _l2BlockTimestamp, bytes32 _prevL2BlockHash) internal {
        // In the unsafe version we do not check that the block data is correct
        currentL2BlockInfo = BlockInfo({number: _l2BlockNumber, timestamp: _l2BlockTimestamp});

        // It is always assumed in production that _l2BlockNumber > 0
        _setL2BlockHash(_l2BlockNumber - 1, _prevL2BlockHash);

        // Resetting the rolling hash
        currentL2BlockTxsRollingHash = bytes32(0);
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
    function setL2Block(
        uint128 _l2BlockNumber,
        uint128 _l2BlockTimestamp,
        bytes32 _expectedPrevL2BlockHash,
        bool _isFirstInBatch
    ) external onlyCallFromBootloader {
        // We check that the timestamp of the L2 block is consistent with the timestamp of the batch.
        if (_isFirstInBatch) {
            uint128 currentBatchTimestamp = currentBatchInfo.timestamp;
            require(
                _l2BlockTimestamp >= currentBatchTimestamp,
                "The timestamp of the L2 block must be greater than or equal to the timestamp of the current batch"
            );
        }

        (uint128 currentL2BlockNumber, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        if (currentL2BlockNumber == 0 && currentL2BlockTimestamp == 0) {
            // Since currentL2BlockNumber and currentL2BlockTimestamp are zero it means that it is
            // the first ever batch with L2 blocks, so we need to initialize those.
            _upgradeL2Blocks(_l2BlockNumber, _expectedPrevL2BlockHash, _isFirstInBatch);

            _setNewL2BlockData(_l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else if (currentL2BlockNumber == _l2BlockNumber) {
            require(!_isFirstInBatch, "Can not reuse L2 block number from the previous batch");
            require(currentL2BlockTimestamp == _l2BlockTimestamp, "The timestamp of the same L2 block must be same");
            require(
                _expectedPrevL2BlockHash == _getLatest257L2blockHash(_l2BlockNumber - 1),
                "The previous hash of the same L2 block must be same"
            );
        } else if (currentL2BlockNumber + 1 == _l2BlockNumber) {
            // From the checks in _upgradeL2Blocks it is known that currentL2BlockNumber can not be 0
            bytes32 prevL2BlockHash = _getLatest257L2blockHash(currentL2BlockNumber - 1);

            bytes32 pendingL2BlockHash = _calculateL2BlockHash(
                currentL2BlockNumber,
                currentL2BlockTimestamp,
                prevL2BlockHash,
                currentL2BlockTxsRollingHash
            );

            require(_expectedPrevL2BlockHash == pendingL2BlockHash, "The current L2 block hash is incorrect");
            require(
                _l2BlockTimestamp > currentL2BlockTimestamp,
                "The timestamp of the new L2 block must be greater than the timestamp of the previous L2 block"
            );

            // Since the new block is created, we'll clear out the rolling hash
            _setNewL2BlockData(_l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else {
            revert("Invalid new L2 block number");
        }
    }

    /// @notice Appends the transaction hash to the rolling hash of the current L2 block.
    /// @param _txHash The hash of the transaction.
    function appendTransactionToCurrentL2Block(bytes32 _txHash) external onlyCallFromBootloader {
        currentL2BlockTxsRollingHash = keccak256(abi.encode(currentL2BlockTxsRollingHash, _txHash));
    }

    /// @notice Publishes L2->L1 logs needed to verify the validity of this batch on L1.
    /// @dev Should be called at the end of the current batch.
    function publishTimestampDataToL1() external onlyCallFromBootloader {
        (uint128 currentBatchNumber, uint128 currentBatchTimestamp) = getBatchNumberAndTimestamp();
        (, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        // The structure of the "setNewBatch" implies that currentBatchNumber > 0, but we still double check it
        require(currentBatchNumber > 0, "The current batch number must be greater than 0");

        // In order to spend less pubdata, the packed version is published
        uint256 packedTimestamps = (uint256(currentBatchTimestamp) << 128) | currentL2BlockTimestamp;

        SystemContractHelper.toL1(
            false,
            bytes32(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)),
            bytes32(packedTimestamps)
        );
    }

    /// @notice Ensures that the timestamp of the batch is greater than the timestamp of the last L2 block.
    /// @param _newTimestamp The timestamp of the new batch.
    function _ensureBatchConsistentWithL2Block(uint128 _newTimestamp) internal view {
        uint128 currentBlockTimestamp = currentL2BlockInfo.timestamp;
        require(
            _newTimestamp > currentBlockTimestamp,
            "The timestamp of the batch must be greater than the timestamp of the previous block"
        );
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
    ) external onlyCallFromBootloader {
        (uint128 previousBatchNumber, uint128 previousBatchTimestamp) = getBatchNumberAndTimestamp();
        require(_newTimestamp > previousBatchTimestamp, "Timestamps should be incremental");
        require(previousBatchNumber + 1 == _expectedNewNumber, "The provided batch number is not correct");

        _ensureBatchConsistentWithL2Block(_newTimestamp);

        batchHashes[previousBatchNumber] = _prevBatchHash;

        // Setting new block number and timestamp
        BlockInfo memory newBlockInfo = BlockInfo({number: previousBatchNumber + 1, timestamp: _newTimestamp});

        currentBatchInfo = newBlockInfo;

        baseFee = _baseFee;

        // The correctness of this block hash:
        SystemContractHelper.toL1(false, bytes32(uint256(SystemLogKey.PREV_BATCH_HASH_KEY)), _prevBatchHash);
    }

    /// @notice A testing method that manually sets the current blocks' number and timestamp.
    /// @dev Should be used only for testing / ethCalls and should never be used in production.
    function unsafeOverrideBatch(
        uint256 _newTimestamp,
        uint256 _number,
        uint256 _baseFee
    ) external onlyCallFromBootloader {
        BlockInfo memory newBlockInfo = BlockInfo({number: uint128(_number), timestamp: uint128(_newTimestamp)});
        currentBatchInfo = newBlockInfo;

        baseFee = _baseFee;
    }

    function incrementTxNumberInBatch() external onlyCallFromBootloader {
        ++txNumberInBlock;
    }

    function resetTxNumberInBatch() external onlyCallFromBootloader {
        txNumberInBlock = 0;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPRECATED METHODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current batch's number and timestamp.
    /// @dev Deprecated in favor of getBatchNumberAndTimestamp.
    function currentBlockInfo() external view returns (uint256 blockInfo) {
        (uint128 blockNumber, uint128 blockTimestamp) = getBatchNumberAndTimestamp();
        blockInfo = (uint256(blockNumber) << 128) | uint256(blockTimestamp);
    }

    /// @notice Returns the current batch's number and timestamp.
    /// @dev Deprecated in favor of getBatchNumberAndTimestamp.
    function getBlockNumberAndTimestamp() external view returns (uint256 blockNumber, uint256 blockTimestamp) {
        (blockNumber, blockTimestamp) = getBatchNumberAndTimestamp();
    }

    /// @notice Returns the hash of the given batch.
    /// @dev Deprecated in favor of getBatchHash.
    function blockHash(uint256 _blockNumber) external view returns (bytes32 hash) {
        hash = batchHashes[_blockNumber];
    }
}
