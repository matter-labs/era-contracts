// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";

/**
 * @author Matter Labs
 * @notice Contract that stores some of the context variables, that may be either
 * block-scoped, tx-scoped or system-wide.
 */
contract SystemContext is ISystemContext {
    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS);
        _;
    }

    /// @notice The chainId of the network. It is set at the genesis.
    uint256 public chainId;

    /// @notice The `tx.origin` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    address public origin;

    /// @notice The `tx.gasPrice` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    uint256 public gasPrice;

    /// @notice The current block's gasLimit.
    uint256 public blockGasLimit = type(uint32).max;

    /// @notice The `block.coinbase` in the current transaction.
    /// @dev For the support of coinbase, we will the bootloader formal address for now
    address public coinbase = BOOTLOADER_FORMAL_ADDRESS;

    /// @notice Formal `block.difficulty` parameter.
    uint256 public difficulty = 2500000000000000;

    /// @notice The `block.basefee`.
    /// @dev It is currently a constant.
    uint256 public baseFee;

    /// @notice The coefficient with which the current block's number
    /// is stored in the current block info
    uint256 constant BLOCK_INFO_BLOCK_NUMBER_PART = 2 ** 128;

    /// @notice block.number and block.timestamp stored packed.
    /// @dev It is equal to 2^128 * block_number + block_timestamp.
    uint256 public currentBlockInfo;

    /// @notice The hashes of blocks.
    /// @dev It stores block hashes for all previous blocks.
    mapping(uint256 => bytes32) public blockHash;

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

    /// @notice The method that emulates `blockhash` opcode in EVM.
    /// @dev Just like the blockhash in the EVM, it returns bytes32(0), when
    /// when queried about hashes that are older than 256 blocks ago.
    function getBlockHashEVM(uint256 _block) external view returns (bytes32 hash) {
        if (block.number < _block || block.number - _block > 256) {
            hash = bytes32(0);
        } else {
            hash = blockHash[_block];
        }
    }

    /// @notice Returns the current blocks' number and timestamp.
    /// @return blockNumber and blockTimestamp tuple of the current block's number and the current block's timestamp
    function getBlockNumberAndTimestamp() public view returns (uint256 blockNumber, uint256 blockTimestamp) {
        uint256 blockInfo = currentBlockInfo;
        blockNumber = blockInfo / BLOCK_INFO_BLOCK_NUMBER_PART;
        blockTimestamp = blockInfo % BLOCK_INFO_BLOCK_NUMBER_PART;
    }

    /// @notice Returns the current block's number.
    /// @return blockNumber The current block's number.
    function getBlockNumber() public view returns (uint256 blockNumber) {
        (blockNumber, ) = getBlockNumberAndTimestamp();
    }

    /// @notice Returns the current block's timestamp.
    /// @return timestamp The current block's timestamp.
    function getBlockTimestamp() public view returns (uint256 timestamp) {
        (, timestamp) = getBlockNumberAndTimestamp();
    }

    /// @notice Increments the current block number and sets the new timestamp
    /// @dev Called by the bootloader at the start of the block.
    /// @param _prevBlockHash The hash of the previous block.
    /// @param _newTimestamp The timestamp of the new block.
    /// @param _expectedNewNumber The new block's number
    /// @dev Whie _expectedNewNumber can be derived as prevBlockNumber + 1, we still
    /// manually supply it here for consistency checks.
    /// @dev The correctness of the _prevBlockHash and _newTimestamp should be enforced on L1.
    function setNewBlock(
        bytes32 _prevBlockHash,
        uint256 _newTimestamp,
        uint256 _expectedNewNumber,
        uint256 _baseFee
    ) external onlyBootloader {
        (uint256 currentBlockNumber, uint256 currentBlockTimestamp) = getBlockNumberAndTimestamp();
        require(_newTimestamp > currentBlockTimestamp, "Timestamps should be incremental");
        require(currentBlockNumber + 1 == _expectedNewNumber, "The provided block number is not correct");

        blockHash[currentBlockNumber] = _prevBlockHash;

        // Setting new block number and timestamp
        currentBlockInfo = (currentBlockNumber + 1) * BLOCK_INFO_BLOCK_NUMBER_PART + _newTimestamp;

        baseFee = _baseFee;

        // The correctness of this block hash and the timestamp will be checked on L1:
        SystemContractHelper.toL1(false, bytes32(_newTimestamp), _prevBlockHash);
    }

    /// @notice A testing method that manually sets the current blocks' number and timestamp.
    /// @dev Should be used only for testing / ethCalls and should never be used in production.
    function unsafeOverrideBlock(uint256 _newTimestamp, uint256 number, uint256 _baseFee) external onlyBootloader {
        currentBlockInfo = (number) * BLOCK_INFO_BLOCK_NUMBER_PART + _newTimestamp;
        baseFee = _baseFee;
    }
}
