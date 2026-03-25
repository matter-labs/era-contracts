// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContextLib, SystemContextStorage} from "../SystemContextLib.sol";
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
    L2_BOOTLOADER_ADDRESS,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Era-specific SystemContext contract. This is a near-verbatim port of the original
 * system-contracts/contracts/SystemContext.sol. The only structural change is that the common
 * `setSettlementLayerChainId` logic is delegated to `SystemContextLib` instead of being
 * duplicated, and storage is accessed through a typed `SystemContextStorage` pointer anchored
 * at slot 0 to enable that delegation.
 * @dev No base contract is used. All storage is declared via `SystemContextStorage` at slot 0.
 * The `batchHashes` mapping (slot 8) is accessed through a dedicated assembly getter because
 * Solidity does not allow mappings inside structs.
 */
contract SystemContextEra is ISystemContextDeprecated {
    using SystemContextLib for SystemContextStorage;

    // ─── Constants ──────────────────────────────────────────────────────────────

    /// @notice The number of latest L2 blocks to store.
    uint256 internal constant MINIBLOCK_HASHES_TO_STORE = 257;

    // ─── Storage ────────────────────────────────────────────────────────────────
    // All state lives in the SystemContextStorage struct at slot 0. No other state
    // variables may be declared in this contract (doing so would shift batchHashes
    // away from slot 8 and break backward compatibility).

    /// @dev Returns the storage pointer anchored at slot 0.
    function _sc() private pure returns (SystemContextStorage storage $) {
        assembly {
            $.slot := 0
        }
    }

    /// @dev Returns a typed storage pointer to the `batchHashes` mapping at slot 8.
    /// Required because Solidity does not allow mappings inside structs.
    function _batchHashes() private pure returns (mapping(uint256 => bytes32) storage m) {
        assembly {
            m.slot := 8
        }
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    // ─── Public getters (backward-compatible with original public state variables) ──

    function chainId() external view returns (uint256) {
        return _sc().chainId;
    }

    function origin() external view returns (address) {
        return _sc().origin;
    }

    function gasPrice() external view returns (uint256) {
        return _sc().gasPrice;
    }

    function blockGasLimit() external view returns (uint256) {
        return _sc().blockGasLimit;
    }

    function coinbase() external view returns (address) {
        return _sc().coinbase;
    }

    function difficulty() external view returns (uint256) {
        return _sc().difficulty;
    }

    function baseFee() external view returns (uint256) {
        return _sc().baseFee;
    }

    function currentSettlementLayerChainId() external view returns (uint256) {
        return _sc().currentSettlementLayerChainId;
    }

    function txNumberInBlock() external view returns (uint16) {
        return _sc().txNumberInBlock;
    }

    function gasPerPubdataByte() external view returns (uint256) {
        return _sc().gasPerPubdataByte;
    }

    // ─── View functions ─────────────────────────────────────────────────────────

    /// @notice Returns the current block's number and timestamp.
    function getL2BlockNumberAndTimestamp() public view returns (uint128 blockNumber, uint128 blockTimestamp) {
        ISystemContext.BlockInfo memory blockInfo = _sc().currentL2BlockInfo;
        blockNumber = blockInfo.number;
        blockTimestamp = blockInfo.timestamp;
    }

    /// @notice Returns the current L2 block's number.
    /// @dev Since zksolc compiler calls this method to emulate `block.number`,
    /// its signature can not be changed to `getL2BlockNumber`.
    function getBlockNumber() public view returns (uint128) {
        return _sc().currentVirtualL2BlockInfo.number;
    }

    /// @notice Returns the current L2 block's timestamp.
    /// @dev Since zksolc compiler calls this method to emulate `block.timestamp`,
    /// its signature can not be changed to `getL2BlockTimestamp`.
    function getBlockTimestamp() public view returns (uint128) {
        return _sc().currentVirtualL2BlockInfo.timestamp;
    }

    /// @notice The method that emulates `blockhash` opcode in EVM.
    /// @dev Since zksolc compiler calls this method to emulate `blockhash`,
    /// its signature can not be changed to `getL2BlockHashEVM`.
    function getBlockHashEVM(uint256 _block) external view returns (bytes32 hash) {
        SystemContextStorage storage $ = _sc();
        uint128 blockNumber = $.currentVirtualL2BlockInfo.number;
        ISystemContext.VirtualBlockUpgradeInfo memory upgradeInfo = $.virtualBlockUpgradeInfo;

        if (blockNumber <= _block || blockNumber - _block > 256) {
            hash = bytes32(0);
        } else if (_block < upgradeInfo.virtualBlockStartBatch) {
            hash = _batchHashes()[_block];
        } else if (_block >= upgradeInfo.virtualBlockFinishL2Block && upgradeInfo.virtualBlockFinishL2Block > 0) {
            hash = _getLatest257L2blockHash($, _block);
        } else {
            hash = keccak256(abi.encode(_block));
        }
    }

    // ─── Mutating functions (bootloader-only) ───────────────────────────────────

    function setChainId(uint256 _newChainId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _sc().chainId = _newChainId;
    }

    /// @notice Updates the settlement layer chain ID.
    /// @dev Skips on the original hard-coded Era chain to avoid calling the asset handler
    /// before the chain ID is properly configured.
    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        if (block.chainid == HARD_CODED_CHAIN_ID) {
            return;
        }
        _sc().setSettlementLayerChainId(_newSettlementLayerChainId);
    }

    function setTxOrigin(address _newOrigin) external onlyBootloader {
        _sc().origin = _newOrigin;
    }

    function setGasPrice(uint256 _gasPrice) external onlyBootloader {
        _sc().gasPrice = _gasPrice;
    }

    function setPubdataInfo(uint256 _gasPerPubdataByte, uint256 _basePubdataSpent) external onlyBootloader {
        _sc().basePubdataSpent = _basePubdataSpent;
        _sc().gasPerPubdataByte = _gasPerPubdataByte;
    }

    function getCurrentPubdataSpent() public view returns (uint256) {
        uint256 pubdataPublished = _getPubdataPublished();
        uint256 basePubdataSpent = _sc().basePubdataSpent;
        return pubdataPublished > basePubdataSpent ? pubdataPublished - basePubdataSpent : 0;
    }

    function getCurrentPubdataCost() external view returns (uint256) {
        return _sc().gasPerPubdataByte * getCurrentPubdataSpent();
    }

    function setL2Block(
        uint128 _l2BlockNumber,
        uint128 _l2BlockTimestamp,
        bytes32 _expectedPrevL2BlockHash,
        bool _isFirstInBatch,
        uint128 _maxVirtualBlocksToCreate
    ) external onlyBootloader {
        SystemContextStorage storage $ = _sc();

        if (_isFirstInBatch) {
            uint128 currentBatchTimestamp = $.currentBatchInfo.timestamp;
            if (_l2BlockTimestamp < currentBatchTimestamp) {
                revert L2BlockAndBatchTimestampMismatch(_l2BlockTimestamp, currentBatchTimestamp);
            }
            if (_maxVirtualBlocksToCreate == 0) {
                revert NoVirtualBlocks();
            }
        }

        (uint128 currentL2BlockNumber, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        if (currentL2BlockNumber == 0 && currentL2BlockTimestamp == 0) {
            _upgradeL2Blocks($, _l2BlockNumber, _expectedPrevL2BlockHash, _isFirstInBatch);
            _setNewL2BlockData($, _l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else if (currentL2BlockNumber == _l2BlockNumber) {
            if (_isFirstInBatch) {
                revert CannotReuseL2BlockNumberFromPreviousBatch();
            }
            if (currentL2BlockTimestamp != _l2BlockTimestamp) {
                revert IncorrectSameL2BlockTimestamp(_l2BlockTimestamp, currentL2BlockTimestamp);
            }
            if (_expectedPrevL2BlockHash != _getLatest257L2blockHash($, _l2BlockNumber - 1)) {
                revert IncorrectSameL2BlockPrevBlockHash(
                    _expectedPrevL2BlockHash,
                    _getLatest257L2blockHash($, _l2BlockNumber - 1)
                );
            }
            if (_maxVirtualBlocksToCreate != 0) {
                revert IncorrectVirtualBlockInsideMiniblock();
            }
        } else if (currentL2BlockNumber + 1 == _l2BlockNumber) {
            bytes32 prevL2BlockHash = _getLatest257L2blockHash($, currentL2BlockNumber - 1);
            bytes32 pendingL2BlockHash = _calculateL2BlockHash(
                currentL2BlockNumber,
                currentL2BlockTimestamp,
                prevL2BlockHash,
                $.currentL2BlockTxsRollingHash
            );

            if (_expectedPrevL2BlockHash != pendingL2BlockHash) {
                revert IncorrectL2BlockHash(_expectedPrevL2BlockHash, pendingL2BlockHash);
            }
            if (_l2BlockTimestamp < currentL2BlockTimestamp) {
                revert NonMonotonicL2BlockTimestamp(_l2BlockTimestamp, currentL2BlockTimestamp);
            }

            _setNewL2BlockData($, _l2BlockNumber, _l2BlockTimestamp, _expectedPrevL2BlockHash);
        } else {
            revert InvalidNewL2BlockNumber(_l2BlockNumber);
        }

        _setVirtualBlock($, _l2BlockNumber, _maxVirtualBlocksToCreate, _l2BlockTimestamp);
    }

    function appendTransactionToCurrentL2Block(bytes32 _txHash) external onlyBootloader {
        _sc().currentL2BlockTxsRollingHash = keccak256(abi.encode(_sc().currentL2BlockTxsRollingHash, _txHash));
    }

    function publishTimestampDataToL1() external onlyBootloader {
        SystemContextStorage storage $ = _sc();
        uint128 currentBatchNumber = $.currentBatchInfo.number;
        (, uint128 currentL2BlockTimestamp) = getL2BlockNumberAndTimestamp();

        if (currentBatchNumber == 0) {
            revert CurrentBatchNumberMustBeGreaterThanZero();
        }

        uint256 packedTimestamps = (uint256($.currentBatchInfo.timestamp) << 128) | currentL2BlockTimestamp;
        _toL1(false, bytes32(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)), bytes32(packedTimestamps));
    }

    function setNewBatch(
        bytes32 _prevBatchHash,
        uint128 _newTimestamp,
        uint128 _expectedNewNumber,
        uint256 _baseFee
    ) external onlyBootloader {
        SystemContextStorage storage $ = _sc();
        uint128 previousBatchNumber = $.currentBatchInfo.number;
        uint128 previousBatchTimestamp = $.currentBatchInfo.timestamp;

        if (_newTimestamp <= previousBatchTimestamp) {
            revert TimestampsShouldBeIncremental(_newTimestamp, previousBatchTimestamp);
        }
        if (previousBatchNumber + 1 != _expectedNewNumber) {
            revert ProvidedBatchNumberIsNotCorrect(previousBatchNumber + 1, _expectedNewNumber);
        }

        _ensureBatchConsistentWithL2Block($, _newTimestamp);

        _batchHashes()[previousBatchNumber] = _prevBatchHash;
        $.currentBatchInfo = ISystemContext.BlockInfo({number: previousBatchNumber + 1, timestamp: _newTimestamp});
        $.baseFee = _baseFee;

        _toL1(false, bytes32(uint256(SystemLogKey.PREV_BATCH_HASH_KEY)), _prevBatchHash);
    }

    function unsafeOverrideBatch(uint256 _newTimestamp, uint256 _number, uint256 _baseFee) external onlyBootloader {
        SystemContextStorage storage $ = _sc();
        $.currentBatchInfo = ISystemContext.BlockInfo({number: uint128(_number), timestamp: uint128(_newTimestamp)});
        $.baseFee = _baseFee;
    }

    function incrementTxNumberInBatch() external onlyBootloader {
        ++_sc().txNumberInBlock;
    }

    function resetTxNumberInBatch() external onlyBootloader {
        _sc().txNumberInBlock = 0;
    }

    // ─── Internal helpers ───────────────────────────────────────────────────────

    function _getLatest257L2blockHash(
        SystemContextStorage storage $,
        uint256 _block
    ) internal view returns (bytes32) {
        return $.l2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE];
    }

    function _setL2BlockHash(SystemContextStorage storage $, uint256 _block, bytes32 _hash) internal {
        $.l2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE] = _hash;
    }

    function _calculateL2BlockHash(
        uint128 _blockNumber,
        uint128 _blockTimestamp,
        bytes32 _prevL2BlockHash,
        bytes32 _blockTxsRollingHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_blockNumber, _blockTimestamp, _prevL2BlockHash, _blockTxsRollingHash));
    }

    function _calculateLegacyL2BlockHash(uint128 _blockNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint32(_blockNumber)));
    }

    function _upgradeL2Blocks(
        SystemContextStorage storage $,
        uint128 _l2BlockNumber,
        bytes32 _expectedPrevL2BlockHash,
        bool _isFirstInBatch
    ) internal {
        if (!_isFirstInBatch) {
            revert UpgradeTransactionMustBeFirst();
        }
        if (_l2BlockNumber == 0) {
            revert L2BlockNumberZero();
        }
        unchecked {
            bytes32 correctPrevBlockHash = _calculateLegacyL2BlockHash(_l2BlockNumber - 1);
            if (correctPrevBlockHash != _expectedPrevL2BlockHash) {
                revert PreviousL2BlockHashIsIncorrect(correctPrevBlockHash, _expectedPrevL2BlockHash);
            }
            _setL2BlockHash($, _l2BlockNumber - 1, correctPrevBlockHash);
        }
    }

    function _setVirtualBlock(
        SystemContextStorage storage $,
        uint128 _l2BlockNumber,
        uint128 _maxVirtualBlocksToCreate,
        uint128 _newTimestamp
    ) internal {
        if ($.virtualBlockUpgradeInfo.virtualBlockFinishL2Block != 0) {
            $.currentVirtualL2BlockInfo = $.currentL2BlockInfo;
            return;
        }

        ISystemContext.BlockInfo memory virtualBlockInfo = $.currentVirtualL2BlockInfo;

        if ($.currentVirtualL2BlockInfo.number == 0 && virtualBlockInfo.timestamp == 0) {
            uint128 currentBatchNumber = $.currentBatchInfo.number;
            virtualBlockInfo.number = currentBatchNumber;
            $.virtualBlockUpgradeInfo.virtualBlockStartBatch = currentBatchNumber;

            if (_maxVirtualBlocksToCreate == 0) {
                revert CannotInitializeFirstVirtualBlock();
            }
            // solhint-disable-next-line gas-increment-by-one
            _maxVirtualBlocksToCreate -= 1;
        } else if (_maxVirtualBlocksToCreate == 0) {
            return;
        }

        virtualBlockInfo.number += _maxVirtualBlocksToCreate;
        virtualBlockInfo.timestamp = _newTimestamp;

        if (virtualBlockInfo.number >= _l2BlockNumber) {
            $.virtualBlockUpgradeInfo.virtualBlockFinishL2Block = _l2BlockNumber;
            virtualBlockInfo.number = _l2BlockNumber;
        }

        $.currentVirtualL2BlockInfo = virtualBlockInfo;
    }

    function _setNewL2BlockData(
        SystemContextStorage storage $,
        uint128 _l2BlockNumber,
        uint128 _l2BlockTimestamp,
        bytes32 _prevL2BlockHash
    ) internal {
        $.currentL2BlockInfo = ISystemContext.BlockInfo({number: _l2BlockNumber, timestamp: _l2BlockTimestamp});
        _setL2BlockHash($, _l2BlockNumber - 1, _prevL2BlockHash);
        $.currentL2BlockTxsRollingHash = bytes32(0);
    }

    function _ensureBatchConsistentWithL2Block(SystemContextStorage storage $, uint128 _newTimestamp) internal view {
        uint128 currentBlockTimestamp = $.currentL2BlockInfo.timestamp;
        if (_newTimestamp < currentBlockTimestamp) {
            revert InconsistentNewBatchTimestamp(_newTimestamp, currentBlockTimestamp);
        }
    }

    /// @dev Sends an L2-to-L1 log (ZkSync-specific). No-op on standard EVM.
    function _toL1(bool _isService, bytes32 _key, bytes32 _value) internal {
        assembly {
            _isService := and(_isService, 1)
            // solhint-disable-next-line no-unused-vars
            let success := call(_isService, 0xFFFF, _key, _value, 0xFFFF, 0, 0)
        }
    }

    /// @dev Gets pubdata published so far (ZkSync-specific). Returns 0 on standard EVM.
    function _getPubdataPublished() internal view returns (uint32 pubdataPublished) {
        uint256 meta;
        assembly {
            meta := staticcall(0, 0xFFFC, 0, 0xFFFF, 0, 0)
        }
        pubdataPublished = uint32(meta);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPRECATED METHODS
    //////////////////////////////////////////////////////////////*/

    // solhint-disable-next-line no-unused-vars
    function getBatchHash(uint256 _batchNumber) external view returns (bytes32 hash) {
        revert DeprecatedFunction(this.getBatchHash.selector);
    }

    function getBatchNumberAndTimestamp() external view returns (uint128 batchNumber, uint128 batchTimestamp) {
        revert DeprecatedFunction(this.getBatchNumberAndTimestamp.selector);
    }

    function currentBlockInfo() external view returns (uint256 blockInfo) {
        revert DeprecatedFunction(this.currentBlockInfo.selector);
    }

    function getBlockNumberAndTimestamp() external view returns (uint256 blockNumber, uint256 blockTimestamp) {
        revert DeprecatedFunction(this.getBlockNumberAndTimestamp.selector);
    }

    // solhint-disable-next-line no-unused-vars
    function blockHash(uint256 _blockNumber) external view returns (bytes32 hash) {
        revert DeprecatedFunction(this.blockHash.selector);
    }
}
