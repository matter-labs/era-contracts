// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for SystemContext implementations (Era and ZK OS).
 * @dev Contains the shared storage layout. The storage layout MUST match the original
 * system-contracts/contracts/SystemContext.sol exactly for Era backward compatibility.
 * @dev This contract does NOT declare interface conformance; concrete subclasses should
 * declare which interfaces they implement (e.g. ISystemContext, ISystemContextDeprecated).
 */
abstract contract SystemContextBase {
    /// @notice The number of latest L2 blocks to store.
    /// @dev EVM requires us to be able to query the hashes of previous 256 blocks.
    /// We could either:
    /// - Store the latest 256 hashes (and strictly rely that we do not accidentally override the hash of the block 256 blocks ago)
    /// - Store the latest 257 blocks' hashes.
    uint256 internal constant MINIBLOCK_HASHES_TO_STORE = 257;

    // ─── Storage slots (must match system-contracts/contracts/SystemContext.sol) ───

    /// @notice The chainId of the network. It is set at the genesis.
    /// @dev Slot 0
    uint256 public chainId;

    /// @notice The `tx.origin` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    /// @dev Slot 1
    address public origin;

    /// @notice The `tx.gasPrice` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader
    /// @dev Slot 2
    uint256 public gasPrice;

    /// @notice The current block's gasLimit.
    /// @dev The same limit is used for both batches and L2 blocks. At this moment this limit is not explicitly
    /// forced by the system, rather it is the responsibility of the operator to ensure that this value is never achieved.
    /// @dev Slot 3
    uint256 public blockGasLimit = (1 << 50);

    /// @notice The `block.coinbase` in the current transaction.
    /// @dev For the support of coinbase, we will use the bootloader formal address for now
    /// @dev Slot 4
    address public coinbase;

    /// @notice Formal `block.difficulty` parameter.
    /// @dev (!) EVM emulator doesn't expect this value to change
    /// @dev Slot 5
    uint256 public difficulty;

    /// @notice The `block.basefee`.
    /// @dev It is currently a constant.
    /// @dev Slot 6
    uint256 public baseFee;

    /// @notice The number and the timestamp of the current L1 batch stored packed.
    /// @dev Slot 7
    ISystemContext.BlockInfo internal currentBatchInfo;

    /// @notice The hashes of batches.
    /// @dev It stores batch hashes for all previous batches.
    /// @dev Slot 8
    mapping(uint256 batchNumber => bytes32 batchHash) internal batchHashes;

    /// @notice The number and the timestamp of the current L2 block.
    /// @dev Slot 9
    ISystemContext.BlockInfo internal currentL2BlockInfo;

    /// @notice The rolling hash of the transactions in the current L2 block.
    /// @dev Slot 10
    bytes32 internal currentL2BlockTxsRollingHash;

    /// @notice The hashes of L2 blocks.
    /// @dev It stores block hashes for previous L2 blocks. Note, in order to make publishing the hashes
    /// of the miniblocks cheaper, we only store the previous MINIBLOCK_HASHES_TO_STORE ones. Since whenever we need to publish a state
    /// diff, a pair of <key, value> is published and for cached keys only 8-byte id is used instead of 32 bytes.
    /// By having this data in a cyclic array of MINIBLOCK_HASHES_TO_STORE blocks, we bring the costs down by 40% (i.e. 40 bytes per miniblock instead of 64 bytes).
    /// @dev The hash of a miniblock with number N would be stored under slot N%MINIBLOCK_HASHES_TO_STORE.
    /// @dev Hashes of the blocks older than the ones which are stored here can be calculated as _calculateLegacyL2BlockHash(blockNumber).
    /// @dev Slots 11-267 (257 slots)
    // solhint-disable-next-line var-name-mixedcase
    bytes32[MINIBLOCK_HASHES_TO_STORE] internal l2BlockHash;

    /// @notice To make migration to L2 blocks smoother, we introduce a temporary concept of virtual L2 blocks, the data
    /// about which will be returned by the EVM-like methods: block.number/block.timestamp/blockhash.
    /// - Their number will start from being equal to the number of the batch and it will increase until it reaches the L2 block number.
    /// - Their timestamp is updated each time a new virtual block is created.
    /// - Their hash is calculated as `keccak256(uint256(number))`
    /// @dev Slot 268
    ISystemContext.BlockInfo internal currentVirtualL2BlockInfo;

    /// @notice The information about the virtual blocks upgrade, which tracks when the migration to the L2 blocks has started and finished.
    /// @dev Slot 269
    ISystemContext.VirtualBlockUpgradeInfo internal virtualBlockUpgradeInfo;

    /// @notice The chainId of the settlement layer.
    /// @notice This value will be deprecated in the future, it should not be used by external contracts.
    /// @dev Slot 270
    uint256 public currentSettlementLayerChainId;

    /// @notice Number of current transaction in block.
    /// @dev Slot 271
    uint16 public txNumberInBlock;

    /// @notice The current gas per pubdata byte
    /// @dev Slot 272
    uint256 public gasPerPubdataByte;

    /// @notice The number of pubdata spent as of the start of the transaction
    /// @dev Slot 273
    uint256 internal basePubdataSpent;

    /// @dev Storage gap to allow adding new shared storage variables in future upgrades.
    // slither-disable-next-line uninitialized-state
    uint256[46] private __gap;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    /// @notice Modifier that makes sure that the method can only be called from the bootloader.
    modifier onlyBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    // ─── Internal helpers ───────────────────────────────────────────────────────

    /// @notice Assuming that block is one of the last MINIBLOCK_HASHES_TO_STORE ones, returns its hash.
    /// @param _block The number of the block.
    /// @return hash The hash of the block.
    function _getLatest257L2blockHash(uint256 _block) internal view returns (bytes32) {
        return l2BlockHash[_block % MINIBLOCK_HASHES_TO_STORE];
    }

    // ─── View functions ─────────────────────────────────────────────────────────

    /// @notice Returns the current block's number and timestamp.
    /// @return blockNumber and blockTimestamp tuple of the current L2 block's number and the current block's timestamp
    function getL2BlockNumberAndTimestamp() public view returns (uint128 blockNumber, uint128 blockTimestamp) {
        ISystemContext.BlockInfo memory blockInfo = currentL2BlockInfo;
        blockNumber = blockInfo.number;
        blockTimestamp = blockInfo.timestamp;
    }

    /// @notice Returns the current L2 block's number.
    /// @dev Since zksolc compiler calls this method to emulate `block.number`,
    /// its signature can not be changed to `getL2BlockNumber`.
    /// @return blockNumber The current L2 block's number.
    function getBlockNumber() public view returns (uint128) {
        return currentVirtualL2BlockInfo.number;
    }

    /// @notice Returns the current L2 block's timestamp.
    /// @dev Since zksolc compiler calls this method to emulate `block.timestamp`,
    /// its signature can not be changed to `getL2BlockTimestamp`.
    /// @return timestamp The current L2 block's timestamp.
    function getBlockTimestamp() public view returns (uint128) {
        return currentVirtualL2BlockInfo.timestamp;
    }

    /// @notice The method that emulates `blockhash` opcode in EVM.
    /// @dev Just like the blockhash in the EVM, it returns bytes32(0),
    /// when queried about hashes that are older than 256 blocks ago.
    /// @dev Since zksolc compiler calls this method to emulate `blockhash`,
    /// its signature can not be changed to `getL2BlockHashEVM`.
    /// @return hash The blockhash of the block with the given number.
    function getBlockHashEVM(uint256 _block) external view returns (bytes32 hash) {
        uint128 blockNumber = currentVirtualL2BlockInfo.number;

        ISystemContext.VirtualBlockUpgradeInfo memory currentVirtualBlockUpgradeInfo = virtualBlockUpgradeInfo;

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
            hash = batchHashes[_block];
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
}
