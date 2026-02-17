// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @dev Enum used for system logs emitted by the bootloader.
/// Separated into its own file to allow importing without pulling in
/// transitive dependencies from Constants.sol.
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
