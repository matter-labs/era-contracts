// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev `keccak256("")`
bytes32 constant EMPTY_STRING_KECCAK = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

/// @dev Bytes in raw L2 log
/// @dev Equal to the bytes size of the tuple - (uint8 ShardId, bool isService, uint16 txNumberInBatch, address sender,
/// bytes32 key, bytes32 value)
uint256 constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

/// @dev The maximum length of the bytes array with L2 -> L1 logs
uint256 constant MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES = 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * 512;

/// @dev The value of default leaf hash for L2 -> L1 logs Merkle tree
/// @dev An incomplete fixed-size tree is filled with this value to be a full binary tree
/// @dev Actually equal to the `keccak256(new bytes(L2_TO_L1_LOG_SERIALIZE_SIZE))`
bytes32 constant L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH = 0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba;

bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = bytes32(0);

/// @dev Denotes the type of the ZKsync Era transaction that came from L1.
uint256 constant PRIORITY_OPERATION_L2_TX_TYPE = 255;

/// @dev Denotes the type of the ZKsync Era transaction that is used for system upgrades.
uint256 constant SYSTEM_UPGRADE_L2_TX_TYPE = 254;

/// @dev Denotes the type of the ZKsync OS transaction that came from L1.
uint256 constant ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE = 127;

/// @dev Denotes the type of the ZKsync OS transaction that is used for system upgrades.
uint256 constant ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE = 126;

/// @dev The maximal allowed difference between protocol minor versions in an upgrade. The 100 gap is needed
/// in case a protocol version has been tested on testnet, but then not launched on mainnet, e.g.
/// due to a bug found.
/// We are allowed to jump at most 100 minor versions at a time. The major version is always expected to be 0.
uint256 constant MAX_ALLOWED_MINOR_VERSION_DELTA = 100;

/// @dev The amount of time in seconds the validator has to process the priority transaction
/// NOTE: The constant is set to zero for the Alpha release period
uint256 constant PRIORITY_EXPIRATION = 0 days;

// @dev The chainId of Ethereum Mainnet
uint256 constant MAINNET_CHAIN_ID = 1;

/// @dev Timestamp - seconds since unix epoch. This value will be used on the mainnet.
uint256 constant MAINNET_COMMIT_TIMESTAMP_NOT_OLDER = 3 days;

/// @dev Timestamp - seconds since unix epoch. This value will be used on testnets.
uint256 constant TESTNET_COMMIT_TIMESTAMP_NOT_OLDER = 30 days;

/// @dev Maximum available error between real commit batch timestamp and analog used in the verifier (in seconds)
/// @dev Must be used cause miner's `block.timestamp` value can differ on some small value (as we know - 12 seconds)
uint256 constant COMMIT_TIMESTAMP_APPROXIMATION_DELTA = 1 hours;

/// @dev Shift to apply to verify public input before verifying.
uint256 constant PUBLIC_INPUT_SHIFT = 32;

/// @dev The maximum number of L2 gas that a user can request for an L2 transaction
uint256 constant MAX_GAS_PER_TRANSACTION = 80_000_000;

/// @dev Even though the price for 1 byte of pubdata is 16 L1 gas, we have a slightly increased
/// value.
uint256 constant L1_GAS_PER_PUBDATA_BYTE = 17;

/// @dev The intrinsic cost of the L1->l2 transaction in computational L2 gas
uint256 constant L1_TX_INTRINSIC_L2_GAS = 167_157;

/// @dev The intrinsic cost of the L1->l2 transaction in pubdata
uint256 constant L1_TX_INTRINSIC_PUBDATA = 88;

/// @dev The minimal base price for L1 transaction
uint256 constant L1_TX_MIN_L2_GAS_BASE = 173_484;

/// @dev The number of L2 gas the transaction starts costing more with each 544 bytes of encoding
uint256 constant L1_TX_DELTA_544_ENCODING_BYTES = 1656;

/// @dev The number of L2 gas an L1->L2 transaction gains with each new factory dependency
uint256 constant L1_TX_DELTA_FACTORY_DEPS_L2_GAS = 2473;

/// @dev The number of L2 gas an L1->L2 transaction gains with each new factory dependency
uint256 constant L1_TX_DELTA_FACTORY_DEPS_PUBDATA = 64;

/// @dev The number of pubdata an L1->L2 transaction requires with each new factory dependency
uint256 constant MAX_NEW_FACTORY_DEPS = 64;

/// @dev The L2 gasPricePerPubdata required to be used in bridges.
uint256 constant REQUIRED_L2_GAS_PRICE_PER_PUBDATA = 800;

/// @dev The native price for L1->L2 transactions in ZKsync OS.
uint256 constant ZKSYNC_OS_L1_TX_NATIVE_PRICE = 10;

/// @dev The intrinsic cost of the L1->L2 transaction in computational L2 gas for ZKsync OS.
uint256 constant L1_TX_INTRINSIC_L2_GAS_ZKSYNC_OS = 21000;

/// @dev The cost of calldata byte for the L1->L2 transaction in computational L2 gas for ZKsync OS.
uint256 constant L1_TX_CALLDATA_PRICE_L2_GAS_ZKSYNC_OS = 16;

/// @dev The static part of the L1->l2 transaction native cost for ZKsync OS.
/// It includes intrinsic cost(130_000) and static part of hashing cost(2500).
uint256 constant L1_TX_STATIC_NATIVE_ZKSYNC_OS = 132_500;

/// @dev The encoding cost per keccak256 round(136 bytes) of the L1->l2 transaction in native resource for ZKsync OS.
uint256 constant L1_TX_ENCODING_136_BYTES_COST_NATIVE_ZKSYNC_OS = 17500;

/// @dev The cost of calldata byte for the L1->L2 transaction in native resource for ZKsync OS.
uint256 constant L1_TX_CALLDATA_COST_NATIVE_ZKSYNC_OS = 1;

/// @dev The intrinsic cost of the L1->l2 transaction in pubdata for ZKsync OS
uint256 constant L1_TX_INTRINSIC_PUBDATA_ZSKYNC_OS = 88;

/// @dev The native per gas ratio for 0 gas price(service/upgrade/gateway) transactions in ZKsync OS.
/// This value is big enough to cover computational native resources usage for any operations.
uint256 constant FREE_TX_NATIVE_PER_GAS = 10_000;

/// @dev The mask which should be applied to the packed batch and L2 block timestamp in order
/// to obtain the L2 block timestamp. Applying this mask is equivalent to calculating modulo 2**128
uint256 constant PACKED_L2_BLOCK_TIMESTAMP_MASK = 0xffffffffffffffffffffffffffffffff;

/// @dev Address of the point evaluation precompile used for EIP-4844 blob verification.
address constant POINT_EVALUATION_PRECOMPILE_ADDR = address(0x0A);

/// @dev The overhead for a transaction slot in L2 gas.
/// It is roughly equal to 80kk/MAX_TRANSACTIONS_IN_BATCH, i.e. how many gas would an L1->L2 transaction
/// need to pay to compensate for the batch being closed.
/// @dev It is expected that the L1 contracts will enforce that the L2 gas price will be high enough to compensate
/// the operator in case the batch is closed because of tx slots filling up.
uint256 constant TX_SLOT_OVERHEAD_L2_GAS = 10000;

/// @dev The overhead for each byte of the bootloader memory that the encoding of the transaction.
/// It is roughly equal to 80kk/BOOTLOADER_MEMORY_FOR_TXS, i.e. how many gas would an L1->L2 transaction
/// need to pay to compensate for the batch being closed.
/// @dev It is expected that the L1 contracts will enforce that the L2 gas price will be high enough to compensate
/// the operator in case the batch is closed because of the memory for transactions being filled up.
uint256 constant MEMORY_OVERHEAD_GAS = 10;

/// @dev The maximum gas limit for a priority transaction in L2.
uint256 constant PRIORITY_TX_MAX_GAS_LIMIT = 72_000_000;

/// @dev the address used to identify eth as the base token for chains.
address constant ETH_TOKEN_ADDRESS = address(1);

/// @dev the value returned in bridgehubDeposit in the TwoBridges function.
bytes32 constant TWO_BRIDGES_MAGIC_VALUE = bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1);

/// @dev https://eips.ethereum.org/EIPS/eip-1352
address constant BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS = address(uint160(type(uint16).max));

/// @dev the maximum number of supported chains, this is an arbitrary limit.
/// @dev Note, that in case of a malicious Bridgehub admin, the total number of chains
/// can be up to 2 times higher. This may be possible, in case the old ChainTypeManager
/// had `100` chains and these were migrated to the Bridgehub only after `MAX_NUMBER_OF_ZK_CHAINS`
/// were added to the bridgehub via creation of new chains.
uint256 constant MAX_NUMBER_OF_ZK_CHAINS = 100;

/// @dev Used as the `msg.sender` for transactions that relayed via a settlement layer.
address constant SETTLEMENT_LAYER_RELAY_SENDER = address(uint160(0x1111111111111111111111111111111111111111));

/// @dev The metadata version that is supported by the ZK Chains to prove that an L2->L1 log was included in a batch.
uint256 constant SUPPORTED_PROOF_METADATA_VERSION = 1;

/// @dev The virtual address of the L1 settlement layer.
address constant L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS = address(
    uint160(uint256(keccak256("L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS")) - 1)
);

struct PriorityTreeCommitment {
    uint256 nextLeafIndex;
    uint256 startIndex;
    uint256 unprocessedIndex;
    bytes32[] sides;
}

// Info that allows to restore a chain.
struct ZKChainCommitment {
    /// @notice Total number of executed batches i.e. batches[totalBatchesExecuted] points at the latest executed batch
    /// (batch 0 is genesis)
    uint256 totalBatchesExecuted;
    /// @notice Total number of proved batches i.e. batches[totalBatchesProved] points at the latest proved batch
    uint256 totalBatchesVerified;
    /// @notice Total number of committed batches i.e. batches[totalBatchesCommitted] points at the latest committed
    /// batch
    uint256 totalBatchesCommitted;
    /// @notice The hash of the L2 system contracts ugpgrade transaction.
    /// @dev It is non zero if the migration happens while the upgrade is not yet finalized.
    bytes32 l2SystemContractsUpgradeTxHash;
    /// @notice The batch when the system contracts upgrade transaction was executed.
    /// @dev It is non-zero if the migration happens while the batch where the upgrade tx was present
    /// has not been finalized (executed) yet.
    uint256 l2SystemContractsUpgradeBatchNumber;
    /// @notice The hashes of the batches that are needed to keep the blockchain working.
    /// @dev The length of the array is equal to the `totalBatchesCommitted - totalBatchesExecuted + 1`, i.e. we need
    /// to store all the unexecuted batches' hashes + 1 latest executed one.
    bytes32[] batchHashes;
    /// @notice Commitment to the priority merkle tree.
    PriorityTreeCommitment priorityTree;
    /// @notice Whether a chain is a permanent rollup.
    bool isPermanentRollup;
    /// @notice The precommitment to the transactions of the latest batch.
    bytes32 precommitmentForTheLatestBatch;
}

/// @dev Used as the `msg.sender` for system service transactions.
address constant SERVICE_TRANSACTION_SENDER = address(uint160(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF));

/// @dev To avoid higher costs the writes, we avoid making the slot zero.
/// This ensures that the cost of writes is always 5k and avoids the 20k initial write from the non-zero value.
bytes32 constant DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH = bytes32(uint256(1));

/// @dev The length of a packed transaction precommitment in bytes. It consists of two parts: 32-byte tx hash and 1-byte status (0 or 1).
uint256 constant PACKED_L2_PRECOMMITMENT_LENGTH = 33;

/// @dev Pubdata commitment scheme used for DA.
/// @param NONE Invalid option.
/// @param EMPTY_NO_DA No DA commitment, used by Validiums.
/// @param PUBDATA_KECCAK256 Keccak of stateDiffHash and keccak(pubdata). Can be used by custom DA solutions.
/// @param BLOBS_AND_PUBDATA_KECCAK256 This commitment includes EIP-4844 blobs data. Used by default RollupL1DAValidator.
/// @param BLOBS_ZKSYNC_OS Keccak of blob versioned hashes filled with pubdata. This commitment scheme is used only for ZKsyncOS.
enum L2DACommitmentScheme {
    NONE,
    EMPTY_NO_DA,
    PUBDATA_KECCAK256,
    BLOBS_AND_PUBDATA_KECCAK256,
    BLOBS_ZKSYNC_OS
}

/// @dev The L2 data availability commitment scheme that permanent rollups are expected to use.
L2DACommitmentScheme constant ROLLUP_L2_DA_COMMITMENT_SCHEME = L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256;

uint256 constant L2_TO_L1_LOGS_MERKLE_TREE_LEAVES = 16_384;

uint256 constant L2_TO_L1_LOGS_MERKLE_TREE_DEPTH = 14 + 1;

/// @dev The start of the pause deposits time window. We pause when migrating to/from gateway.
uint256 constant PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET = 3 days + 12 hours;

/// @dev The start of the chain migration window, it equals the PAUSE_DEPOSITS_TIME_WINDOW_START.
uint256 constant CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET = 3 days + 12 hours;

/// @dev The end of the chain migration window.
uint256 constant CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET = 4 days + 12 hours;

/// @dev The end of the pause deposits time window. We pause when migrating to/from gateway.
uint256 constant PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET = 7 days;

uint256 constant PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET = 1;

uint256 constant CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET = 1;

uint256 constant CHAIN_MIGRATION_TIME_WINDOW_END_TESTNET = 1 days;

uint256 constant PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET = 2 days;

/// @dev Default overhead value in L1 gas for each batch during chain creation.
uint32 constant DEFAULT_BATCH_OVERHEAD_L1_GAS = 1_000_000;

/// @dev Default maximum amount of pubdata per batch during chain creation.
uint32 constant DEFAULT_MAX_PUBDATA_PER_BATCH = 120_000;

/// @dev Default maximum amount of L2 gas per batch during chain creation.
uint32 constant DEFAULT_MAX_L2_GAS_PER_BATCH = 80_000_000;

/// @dev Default maximum amount of pubdata for priority transactions during chain creation.
uint32 constant DEFAULT_PRIORITY_TX_MAX_PUBDATA = 99_000;

/// @dev Default minimum L2 gas price (in wei) for L1->L2 transactions during chain creation.
uint64 constant DEFAULT_MINIMAL_L2_GAS_PRICE = 250_000_000;

/// @notice The struct that describes whether users will be charged for pubdata for L1->L2 transactions.
/// @param Rollup The users are charged for pubdata & it is priced based on the gas price on Ethereum.
/// @param Validium The pubdata is considered free with regard to the L1 gas price.
enum PubdataPricingMode {
    Rollup,
    Validium
}

/// @dev Default pubdata pricing mode during chain creation.
PubdataPricingMode constant DEFAULT_PUBDATA_PRICING_MODE = PubdataPricingMode.Rollup;

/// @dev Default maximum gas limit for priority transactions during chain creation.
uint64 constant DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT = 72_000_000;
