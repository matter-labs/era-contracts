// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @dev The formal address of the initial program of the system: the bootloader
address constant L2_BOOTLOADER_ADDRESS = address(0x8001);

/// @dev The address of the known code storage system contract
address constant L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR = address(0x8004);

/// @dev The address of the L2 deployer system contract.
address constant L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(0x8006);

/// @dev The special reserved L2 address. It is located in the system contracts space but doesn't have deployed
/// bytecode.
/// @dev The L2 deployer system contract allows changing bytecodes on any address if the `msg.sender` is this address.
/// @dev So, whenever the governor wants to redeploy system contracts, it just initiates the L1 upgrade call deployer
/// system contract
/// via the L1 -> L2 transaction with `sender == L2_FORCE_DEPLOYER_ADDR`. For more details see the
/// `diamond-initializers` contracts.
address constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);

/// @dev The address of the special smart contract that can send arbitrary length message as an L2 log
address constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR = address(0x8008);

/// @dev The address of the eth token system contract
address constant L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = address(0x800a);

/// @dev The address of the context system contract
address constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR = address(0x800b);

/// @dev The address of the pubdata chunk publisher contract
address constant L2_PUBDATA_CHUNK_PUBLISHER_ADDR = address(0x8011);
