// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for SystemContext implementations (Era and ZK OS).
 * @dev Contains the shared storage layout. The storage layout MUST match the original
 * system-contracts/contracts/SystemContext.sol exactly for Era backward compatibility.
 * @dev This contract does NOT declare interface conformance; concrete subclasses should
 * declare which interfaces they implement (e.g. ISystemContext, ISystemContextDeprecated).
 * @dev Only storage slots, the bootloader modifier, and helpers shared by both Era and ZKOS
 * live here. Era-specific storage variables are prefixed with `_era` to make clear they
 * must not be read or written from ZKOS or shared code.
 * @dev No public functions are declared in this base — all public methods belong exclusively
 * to the concrete subclass that owns them.
 */
abstract contract SystemContextBase {
    // ─── Constants ──────────────────────────────────────────────────────────────

    /// @notice The number of latest L2 blocks to store.
    /// @dev EVM requires us to be able to query the hashes of previous 256 blocks.
    /// We could either:
    /// - Store the latest 256 hashes (and strictly rely that we do not accidentally override the hash of the block 256 blocks ago)
    /// - Store the latest 257 blocks' hashes.
    uint256 internal constant MINIBLOCK_HASHES_TO_STORE = 257;

    // ─── Events ─────────────────────────────────────────────────────────────────

    /// @notice Emitted when the Settlement Layer chain id is modified.
    event SettlementLayerChainIdUpdated(uint256 indexed _newSettlementLayerChainId);

    // ─── Storage slots (must match system-contracts/contracts/SystemContext.sol) ───

    /// @notice The chainId of the network. It is set at the genesis.
    /// @dev Slot 0
    uint256 public chainId;

    /// @notice [Era-specific] The `tx.origin` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader.
    /// @dev Slot 1
    address internal _eraOrigin;

    /// @notice [Era-specific] The `tx.gasPrice` in the current transaction.
    /// @dev It is updated before each transaction by the bootloader.
    /// @dev Slot 2
    uint256 internal _eraGasPrice;

    /// @notice [Era-specific] The current block's gasLimit.
    /// @dev The same limit is used for both batches and L2 blocks. At this moment this limit is not explicitly
    /// forced by the system, rather it is the responsibility of the operator to ensure that this value is never achieved.
    /// @dev Slot 3
    // solhint-disable-next-line var-name-mixedcase
    uint256 internal _eraBlockGasLimit = (1 << 50);

    /// @notice [Era-specific] The `block.coinbase` in the current transaction.
    /// @dev For the support of coinbase, we will use the bootloader formal address for now.
    /// @dev Slot 4
    address internal _eraCoinbase;

    /// @notice [Era-specific] Formal `block.difficulty` parameter.
    /// @dev (!) EVM emulator doesn't expect this value to change.
    /// @dev Slot 5
    uint256 internal _eraDifficulty;

    /// @notice [Era-specific] The `block.basefee`.
    /// @dev It is currently a constant.
    /// @dev Slot 6
    uint256 internal _eraBaseFee;

    /// @notice [Era-specific] The number and the timestamp of the current L1 batch stored packed.
    /// @dev Slot 7
    ISystemContext.BlockInfo internal _eraCurrentBatchInfo;

    /// @notice [Era-specific] The hashes of batches.
    /// @dev It stores batch hashes for all previous batches.
    /// @dev Slot 8
    mapping(uint256 batchNumber => bytes32 batchHash) internal _eraBatchHashes;

    /// @notice [Era-specific] The number and the timestamp of the current L2 block.
    /// @dev Slot 9
    ISystemContext.BlockInfo internal _eraCurrentL2BlockInfo;

    /// @notice [Era-specific] The rolling hash of the transactions in the current L2 block.
    /// @dev Slot 10
    bytes32 internal _eraCurrentL2BlockTxsRollingHash;

    /// @notice [Era-specific] The hashes of L2 blocks.
    /// @dev It stores block hashes for previous L2 blocks. Note, in order to make publishing the hashes
    /// of the miniblocks cheaper, we only store the previous MINIBLOCK_HASHES_TO_STORE ones. Since whenever we need to publish a state
    /// diff, a pair of <key, value> is published and for cached keys only 8-byte id is used instead of 32 bytes.
    /// By having this data in a cyclic array of MINIBLOCK_HASHES_TO_STORE blocks, we bring the costs down by 40% (i.e. 40 bytes per miniblock instead of 64 bytes).
    /// @dev The hash of a miniblock with number N would be stored under slot N%MINIBLOCK_HASHES_TO_STORE.
    /// @dev Hashes of the blocks older than the ones which are stored here can be calculated as _calculateLegacyL2BlockHash(blockNumber).
    /// @dev Slots 11-267 (257 slots)
    // solhint-disable-next-line var-name-mixedcase
    bytes32[MINIBLOCK_HASHES_TO_STORE] internal _eraL2BlockHash;

    /// @notice [Era-specific] Virtual L2 block info used during the migration to L2 blocks.
    /// @dev To make migration to L2 blocks smoother, we introduce a temporary concept of virtual L2 blocks, the data
    /// about which will be returned by the EVM-like methods: block.number/block.timestamp/blockhash.
    /// - Their number will start from being equal to the number of the batch and it will increase until it reaches the L2 block number.
    /// - Their timestamp is updated each time a new virtual block is created.
    /// - Their hash is calculated as `keccak256(uint256(number))`
    /// @dev Slot 268
    ISystemContext.BlockInfo internal _eraCurrentVirtualL2BlockInfo;

    /// @notice [Era-specific] The information about the virtual blocks upgrade.
    /// @dev Tracks when the migration to the L2 blocks has started and finished.
    /// @dev Slot 269
    ISystemContext.VirtualBlockUpgradeInfo internal _eraVirtualBlockUpgradeInfo;

    /// @notice The chainId of the settlement layer.
    /// @notice This value will be deprecated in the future, it should not be used by external contracts.
    /// @dev Slot 270
    uint256 public currentSettlementLayerChainId;

    /// @notice [Era-specific] Number of current transaction in block.
    /// @dev Slot 271
    uint16 internal _eraTxNumberInBlock;

    /// @notice [Era-specific] The current gas per pubdata byte.
    /// @dev Slot 272
    uint256 internal _eraGasPerPubdataByte;

    /// @notice [Era-specific] The number of pubdata spent as of the start of the transaction.
    /// @dev Slot 273
    uint256 internal _eraBasePubdataSpent;

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

    /// @notice Updates the settlement layer chain ID, calling the chain asset handler and emitting
    /// an event when the value actually changes. Shared by both Era and ZKOS implementations.
    /// @param _newSettlementLayerChainId The new settlement layer chain ID.
    function _setSettlementLayerChainId(uint256 _newSettlementLayerChainId) internal {
        if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
            // slither-disable-next-line reentrancy-no-eth
            IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(
                currentSettlementLayerChainId,
                _newSettlementLayerChainId
            );
            currentSettlementLayerChainId = _newSettlementLayerChainId;
            emit SettlementLayerChainIdUpdated(_newSettlementLayerChainId);
        }
    }
}
