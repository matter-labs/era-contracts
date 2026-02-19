// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @notice This file contains pure value constants and enums.
/// Interface-typed constants (e.g. IContractDeployer constant DEPLOYER_SYSTEM_CONTRACT) are in Contracts.sol.

/// @dev All the system contracts introduced by ZKsync have their addresses
/// started from 2^15 in order to avoid collision with Ethereum precompiles.
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15

/// @dev Unlike the value above, it is not overridden for the purpose of testing and
/// is identical to the constant value actually used as the system contracts offset on
/// mainnet.
uint160 constant REAL_SYSTEM_CONTRACTS_OFFSET = 0x8000;

/// @dev All the system contracts must be located in the kernel space,
/// i.e. their addresses must be below 2^16.
uint160 constant MAX_SYSTEM_CONTRACT_ADDRESS = 0xffff; // 2^16 - 1

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant USER_CONTRACTS_OFFSET = MAX_SYSTEM_CONTRACT_ADDRESS + 1;

address constant ECRECOVER_SYSTEM_CONTRACT = address(0x01);
address constant SHA256_SYSTEM_CONTRACT = address(0x02);
address constant IDENTITY_SYSTEM_CONTRACT = address(0x04);
address constant MODEXP_SYSTEM_CONTRACT = address(0x05);
address constant ECADD_SYSTEM_CONTRACT = address(0x06);
address constant ECMUL_SYSTEM_CONTRACT = address(0x07);
address constant ECPAIRING_SYSTEM_CONTRACT = address(0x08);

/// @dev The number of gas that need to be spent for a single byte of pubdata regardless of the pubdata price.
/// This variable is used to ensure the following:
/// - That the long-term storage of the operator is compensated properly.
/// - That it is not possible that the pubdata counter grows too high without spending proportional amount of computation.
uint256 constant COMPUTATIONAL_PRICE_FOR_PUBDATA = 80;

/// @dev The maximal possible address of an L1-like precompie. These precompiles maintain the following properties:
/// - Their extcodehash is EMPTY_STRING_KECCAK
/// - Their extcodesize is 0 despite having a bytecode formally deployed there.
uint256 constant CURRENT_MAX_PRECOMPILE_ADDRESS = 0xff;

address payable constant BOOTLOADER_FORMAL_ADDRESS = payable(address(SYSTEM_CONTRACTS_OFFSET + 0x01));

// A contract that is allowed to deploy any codehash
// on any address. To be used only during an upgrade.
address constant FORCE_DEPLOYER = address(SYSTEM_CONTRACTS_OFFSET + 0x07);
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);

// It will be a different value for tests, while shouldn't. But for now, this constant is not used by other contracts, so that's fine.
address constant EVENT_WRITER_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x0d);

// Hardcoded because even for tests we should keep the address. (Instead `SYSTEM_CONTRACTS_OFFSET + 0x10`)
// Precompile call depends on it.
// And we don't want to mock this contract.
address constant KECCAK256_SYSTEM_CONTRACT = address(0x8010);

address constant CODE_ORACLE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x12);

address constant EVM_GAS_MANAGER = address(SYSTEM_CONTRACTS_OFFSET + 0x13);
address constant EVM_PREDEPLOYS_MANAGER = address(SYSTEM_CONTRACTS_OFFSET + 0x14);

address constant L2_DA_VALIDATOR = address(SYSTEM_CONTRACTS_OFFSET + 0x16);

address constant L2_NATIVE_TOKEN_VAULT_ADDR = address(USER_CONTRACTS_OFFSET + 0x04);
// Note, that on its own this contract does not provide much functionality, but having it on a constant address
// serves as a convenient storage for its bytecode to be accessible via `extcodehash`.
address constant SLOAD_CONTRACT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x06);

address constant WRAPPED_BASE_TOKEN_IMPL_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x07);
address constant L2_CHAIN_ASSET_HANDLER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0a);
address constant L2_UPGRADEABLE_BEACON_DEPLOYER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0b);
address constant L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0c);

address constant L2_INTEROP_CENTER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0d);
address constant L2_INTEROP_HANDLER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0e);
address constant L2_ASSET_TRACKER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x0f);
address constant GW_ASSET_TRACKER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x10);

/// @dev If the bitwise AND of the extraAbi[2] param when calling the MSG_VALUE_SIMULATOR
/// is non-zero, the call will be assumed to be a system one.
uint256 constant MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT = 1;

/// @dev The maximal msg.value that context can have
uint256 constant MAX_MSG_VALUE = type(uint128).max;

/// @dev Prefix used during derivation of account addresses using CREATE2
/// @dev keccak256("zksyncCreate2")
bytes32 constant CREATE2_PREFIX = 0x2020dba91b30cc0006188af794c2fb30dd8520db7e2c088b7fc7c103c00ca494;
/// @dev Prefix used during derivation of account addresses using CREATE
/// @dev keccak256("zksyncCreate")
bytes32 constant CREATE_PREFIX = 0x63bae3a9951d38e8a3fbb7b70909afc1200610fc5bc55ade242f815974674f23;

/// @dev Prefix used during derivation of account addresses using CREATE2 within the EVM
bytes1 constant CREATE2_EVM_PREFIX = 0xff;

/// @dev Each state diff consists of 156 bytes of actual data and 116 bytes of unused padding, needed for circuit efficiency.
uint256 constant STATE_DIFF_ENTRY_SIZE = 272;

/// @dev Bytes in raw L2 to L1 log
/// @dev Equal to the bytes size of the tuple - (uint8 ShardId, bool isService, uint16 txNumberInBlock, address sender, bytes32 key, bytes32 value)
uint256 constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

/// @dev The value of default leaf hash for L2 to L1 logs Merkle tree
/// @dev An incomplete fixed-size tree is filled with this value to be a full binary tree
/// @dev Actually equal to the `keccak256(new bytes(L2_TO_L1_LOG_SERIALIZE_SIZE))`
bytes32 constant L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH = 0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba;

/// @dev The current version of state diff compression being used.
uint256 constant STATE_DIFF_COMPRESSION_VERSION_NUMBER = 1;

/// @dev Enum used for system logs emitted by the bootloader.
enum SystemLogKey {
    L2_TO_L1_LOGS_TREE_ROOT_KEY,
    PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
    CHAINED_PRIORITY_TXN_HASH_KEY,
    NUMBER_OF_LAYER_1_TXS_KEY,
    // Note, that it is important that `PREV_BATCH_HASH_KEY` has position
    // `4` since it is the same as it was in the previous protocol version and
    // it is the only one that is emitted before the system contracts are upgraded.
    PREV_BATCH_HASH_KEY,
    L2_DA_VALIDATOR_OUTPUT_HASH_KEY,
    USED_L2_DA_VALIDATION_COMMITMENT_SCHEME_KEY,
    MESSAGE_ROOT_ROLLING_HASH_KEY,
    L2_TXS_STATUS_ROLLING_HASH_KEY,
    SETTLEMENT_LAYER_CHAIN_ID_KEY,
    EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY
}

/// @dev The number of leaves in the L2->L1 log Merkle tree.
/// While formally a tree of any length is acceptable, the node supports only a constant length of 16384 leaves.
uint256 constant L2_TO_L1_LOGS_MERKLE_TREE_LEAVES = 16_384;

uint256 constant L2_TO_L1_LOGS_MERKLE_TREE_DEPTH = 14 + 1;

/// @dev The length of the derived key in bytes inside compressed state diffs.
uint256 constant DERIVED_KEY_LENGTH = 32;
/// @dev The length of the enum index in bytes inside compressed state diffs.
uint256 constant ENUM_INDEX_LENGTH = 8;
/// @dev The length of value in bytes inside compressed state diffs.
uint256 constant VALUE_LENGTH = 32;

/// @dev The length of the compressed initial storage write in bytes.
uint256 constant COMPRESSED_INITIAL_WRITE_SIZE = DERIVED_KEY_LENGTH + VALUE_LENGTH;
/// @dev The length of the compressed repeated storage write in bytes.
uint256 constant COMPRESSED_REPEATED_WRITE_SIZE = ENUM_INDEX_LENGTH + VALUE_LENGTH;

/// @dev The position from which the initial writes start in the compressed state diffs.
uint256 constant INITIAL_WRITE_STARTING_POSITION = 4;

/// @dev Each storage diffs consists of the following elements:
/// [20bytes address][32bytes key][32bytes derived key][8bytes enum index][32bytes initial value][32bytes final value]
/// @dev The offset of the derived key in a storage diff.
uint256 constant STATE_DIFF_DERIVED_KEY_OFFSET = 52;
/// @dev The offset of the enum index in a storage diff.
uint256 constant STATE_DIFF_ENUM_INDEX_OFFSET = 84;
/// @dev The offset of the final value in a storage diff.
uint256 constant STATE_DIFF_FINAL_VALUE_OFFSET = 124;

/// @dev Total number of bytes in a blob. Blob = 4096 field elements * 31 bytes per field element
/// @dev EIP-4844 defines it as 131_072 but we use 4096 * 31 within our circuits to always fit within a field element
/// @dev Our circuits will prove that a EIP-4844 blob and our internal blob are the same.
uint256 constant BLOB_SIZE_BYTES = 126_976;

/// @dev Max number of blobs currently supported
uint256 constant MAX_NUMBER_OF_BLOBS = 6;

/// @dev Marker of EraVM bytecode
uint8 constant ERA_VM_BYTECODE_FLAG = 1;
/// @dev Marker of EVM bytecode
uint8 constant EVM_BYTECODE_FLAG = 2;

address constant SERVICE_CALL_PSEUDO_CALLER = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

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

/// @dev The metadata version that is supported by the ZK Chains to prove that an L2->L1 log was included in a batch.
uint256 constant SUPPORTED_PROOF_METADATA_VERSION = 1;

/// @dev The server has a hardcoded chainId 270 which is updated to the real value in the L2GenesisUpgradeTxs
/// see link: https://github.com/matter-labs/zksync-era/blob/54dc61c6faff53d314227ffe26961b1abfc999a7/core/node/genesis/src/lib.rs#L182
/// https://github.com/matter-labs/zksync-era/blob/54dc61c6faff53d314227ffe26961b1abfc999a7/core/lib/basic_types/src/lib.rs#L228
uint256 constant HARD_CODED_CHAIN_ID = 270;
