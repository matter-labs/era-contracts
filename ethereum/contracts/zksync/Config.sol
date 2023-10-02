// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

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

/// @dev Number of bytes in a one initial storage change
/// @dev Equal to the bytes size of the tuple - (bytes32 key, bytes32 value)
uint256 constant INITIAL_STORAGE_CHANGE_SERIALIZE_SIZE = 64;

/// @dev The maximum length of the bytes array with initial storage changes
uint256 constant MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES = 4 + INITIAL_STORAGE_CHANGE_SERIALIZE_SIZE * 4765;

/// @dev Number of bytes in a one repeated storage change
/// @dev Equal to the bytes size of the tuple - (bytes8 key, bytes32 value)
uint256 constant REPEATED_STORAGE_CHANGE_SERIALIZE_SIZE = 40;

/// @dev The maximum length of the bytes array with repeated storage changes
uint256 constant MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES = 4 + REPEATED_STORAGE_CHANGE_SERIALIZE_SIZE * 7564;

// TODO: change constant to the real root hash of empty Merkle tree (SMA-184)
bytes32 constant DEFAULT_L2_LOGS_TREE_ROOT_HASH = bytes32(0);

/// @dev Denotes the type of the zkSync transaction that came from L1.
uint256 constant PRIORITY_OPERATION_L2_TX_TYPE = 255;

/// @dev Denotes the type of the zkSync transaction that is used for system upgrades.
uint256 constant SYSTEM_UPGRADE_L2_TX_TYPE = 254;

/// @dev The amount of time in seconds the validator has to process the priority transaction
/// NOTE: The constant is set to zero for the Alpha release period
uint256 constant PRIORITY_EXPIRATION = 0 days;

/// @dev Notice period before activation preparation status of upgrade mode (in seconds)
/// @dev NOTE: we must reserve for users enough time to send full exit operation, wait maximum time for processing this
/// operation and withdraw funds from it.
uint256 constant UPGRADE_NOTICE_PERIOD = $$(defined(UPGRADE_NOTICE_PERIOD) ? UPGRADE_NOTICE_PERIOD : "14 days");

/// @dev Timestamp - seconds since unix epoch
uint256 constant COMMIT_TIMESTAMP_NOT_OLDER = $$(
    defined(COMMIT_TIMESTAMP_NOT_OLDER) ? COMMIT_TIMESTAMP_NOT_OLDER : "365 days"
);

/// @dev Maximum available error between real commit block timestamp and analog used in the verifier (in seconds)
/// @dev Must be used cause miner's `block.timestamp` value can differ on some small value (as we know - 15 seconds)
uint256 constant COMMIT_TIMESTAMP_APPROXIMATION_DELTA = $$(
    defined(COMMIT_TIMESTAMP_APPROXIMATION_DELTA) ? COMMIT_TIMESTAMP_APPROXIMATION_DELTA : "365 days"
);

/// @dev Bit mask to apply for verifier public input before verifying.
uint256 constant INPUT_MASK = $$(~uint256(0) >> 32);

/// @dev The maximum number of L2 gas that a user can request for an L2 transaction
uint256 constant L2_TX_MAX_GAS_LIMIT = $(L2_TX_MAX_GAS_LIMIT);

/// @dev The maximum number of the pubdata an L2 operation should be allowed to use.
uint256 constant MAX_PUBDATA_PER_BATCH = $(MAX_PUBDATA_PER_BATCH);

/// @dev The maximum number of the pubdata an priority operation should be allowed to use.
/// For now, it is somewhat lower than the maximum number of pubdata allowed for an L2 transaction,
/// to ensure that the transaction is definitely processable on L2 despite any potential overhead.
uint256 constant PRIORITY_TX_MAX_PUBDATA = $(PRIORITY_TX_MAX_PUBDATA);

/// @dev The default price per L2 gas to be used for L1->L2 transactions
uint256 constant FAIR_L2_GAS_PRICE = $(FAIR_L2_GAS_PRICE);

/// @dev Even though the price for 1 byte of pubdata is 16 L1 gas, we have a slightly increased
/// value.
uint256 constant L1_GAS_PER_PUBDATA_BYTE = $(L1_GAS_PER_PUBDATA_BYTE);

/// @dev The computational overhead of processing an L2 batch.
uint256 constant BATCH_OVERHEAD_L2_GAS = $(BATCH_OVERHEAD_L2_GAS);

/// @dev The overhead in L1 gas of interacting with the L1
uint256 constant BATCH_OVERHEAD_L1_GAS = $(BATCH_OVERHEAD_L1_GAS);

/// @dev The equivalent in L1 pubdata of L1 gas used for working with L1
uint256 constant BATCH_OVERHEAD_PUBDATA = BATCH_OVERHEAD_L1_GAS / L1_GAS_PER_PUBDATA_BYTE;

/// @dev The maximum number of transactions in L2 batch:
uint256 constant MAX_TRANSACTIONS_IN_BATCH = $(MAX_TRANSACTIONS_IN_BATCH);

/// @dev The size of the bootloader memory dedicated to the encodings of transactions
uint256 constant BOOTLOADER_TX_ENCODING_SPACE = $(BOOTLOADER_TX_ENCODING_SPACE);

/// @dev The intrinsic cost of the L1->l2 transaction in computational L2 gas
uint256 constant L1_TX_INTRINSIC_L2_GAS = $(L1_TX_INTRINSIC_L2_GAS);

/// @dev The intrinsic cost of the L1->l2 transaction in pubdata
uint256 constant L1_TX_INTRINSIC_PUBDATA = $(L1_TX_INTRINSIC_PUBDATA);

/// @dev The minimal base price for L1 transaction
uint256 constant L1_TX_MIN_L2_GAS_BASE = $(L1_TX_MIN_L2_GAS_BASE);

/// @dev The number of L2 gas the transaction starts costing more with each 544 bytes of encoding
uint256 constant L1_TX_DELTA_544_ENCODING_BYTES = $(L1_TX_DELTA_544_ENCODING_BYTES);

/// @dev The number of L2 gas an L1->L2 transaction gains with each new factory dependency
uint256 constant L1_TX_DELTA_FACTORY_DEPS_L2_GAS = $(L1_TX_DELTA_FACTORY_DEPS_L2_GAS);

/// @dev The number of L2 gas an L1->L2 transaction gains with each new factory dependency
uint256 constant L1_TX_DELTA_FACTORY_DEPS_PUBDATA = $(L1_TX_DELTA_FACTORY_DEPS_PUBDATA);

/// @dev The number of pubdata an L1->L2 transaction requires with each new factory dependency
uint256 constant MAX_NEW_FACTORY_DEPS = $(MAX_NEW_FACTORY_DEPS);

/// @dev The L2 gasPricePerPubdata required to be used in bridges.
uint256 constant REQUIRED_L2_GAS_PRICE_PER_PUBDATA = $(REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

/// @dev The mask which should be applied to the packed batch and L2 block timestamp in order
/// to obtain the L2 block timestamp. Applying this mask is equivalent to calculating modulo 2**128
uint256 constant PACKED_L2_BLOCK_TIMESTAMP_MASK = 0xffffffffffffffffffffffffffffffff;
