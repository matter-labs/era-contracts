// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

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

// TODO: change constant to the real root hash of empty Merkle tree (SMA-184)
bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = bytes32(0);

/// @dev Denotes the type of the zkSync transaction that came from L1.
uint256 constant PRIORITY_OPERATION_L2_TX_TYPE = 255;

/// @dev Denotes the type of the zkSync transaction that is used for system upgrades.
uint256 constant SYSTEM_UPGRADE_L2_TX_TYPE = 254;

/// @dev The maximal allowed difference between protocol minor versions in an upgrade. The 100 gap is needed
/// in case a protocol version has been tested on testnet, but then not launched on mainnet, e.g.
/// due to a bug found.
/// We are allowed to jump at most 100 minor versions at a time. The major version is always expected to be 0.
uint256 constant MAX_ALLOWED_MINOR_VERSION_DELTA = 100;

/// @dev The amount of time in seconds the validator has to process the priority transaction
/// NOTE: The constant is set to zero for the Alpha release period
uint256 constant PRIORITY_EXPIRATION = 0 days;

/// @dev Timestamp - seconds since unix epoch.
uint256 constant COMMIT_TIMESTAMP_NOT_OLDER = 3 days;

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
uint256 constant MAX_NEW_FACTORY_DEPS = 32;

/// @dev The L2 gasPricePerPubdata required to be used in bridges.
uint256 constant REQUIRED_L2_GAS_PRICE_PER_PUBDATA = 800;

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

address constant ETH_TOKEN_ADDRESS = address(1);

bytes32 constant TWO_BRIDGES_MAGIC_VALUE = bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1);

/// @dev https://eips.ethereum.org/EIPS/eip-1352
address constant BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS = address(uint160(type(uint16).max));
