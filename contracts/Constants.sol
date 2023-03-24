// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IAccountCodeStorage.sol";
import "./interfaces/INonceHolder.sol";
import "./interfaces/IContractDeployer.sol";
import "./interfaces/IKnownCodesStorage.sol";
import "./interfaces/IImmutableSimulator.sol";
import "./interfaces/IEthToken.sol";
import "./interfaces/IL1Messenger.sol";
import "./interfaces/ISystemContext.sol";
import "./interfaces/IBytecodeCompressor.sol";
import "./BootloaderUtilities.sol";

/// @dev All the system contracts introduced by zkSync have their addresses
/// started from 2^15 in order to avoid collision with Ethereum precompiles.
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15

/// @dev All the system contracts must be located in the kernel space,
/// i.e. their addresses must be below 2^16.
uint160 constant MAX_SYSTEM_CONTRACT_ADDRESS = 0xffff; // 2^16 - 1

address constant ECRECOVER_SYSTEM_CONTRACT = address(0x01);
address constant SHA256_SYSTEM_CONTRACT = address(0x02);

/// @dev The current maximum deployed precompile address.
/// Note: currently only two precompiles are deployed:
/// 0x01 - ecrecover
/// 0x02 - sha256
/// Important! So the constant should be updated if more precompiles are deployed.
uint256 constant CURRENT_MAX_PRECOMPILE_ADDRESS = uint256(uint160(SHA256_SYSTEM_CONTRACT));

address payable constant BOOTLOADER_FORMAL_ADDRESS = payable(address(SYSTEM_CONTRACTS_OFFSET + 0x01));
IAccountCodeStorage constant ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT = IAccountCodeStorage(
    address(SYSTEM_CONTRACTS_OFFSET + 0x02)
);
INonceHolder constant NONCE_HOLDER_SYSTEM_CONTRACT = INonceHolder(address(SYSTEM_CONTRACTS_OFFSET + 0x03));
IKnownCodesStorage constant KNOWN_CODE_STORAGE_CONTRACT = IKnownCodesStorage(address(SYSTEM_CONTRACTS_OFFSET + 0x04));
IImmutableSimulator constant IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT = IImmutableSimulator(
    address(SYSTEM_CONTRACTS_OFFSET + 0x05)
);
IContractDeployer constant DEPLOYER_SYSTEM_CONTRACT = IContractDeployer(address(SYSTEM_CONTRACTS_OFFSET + 0x06));

// A contract that is allowed to deploy any codehash
// on any address. To be used only during an upgrade.
address constant FORCE_DEPLOYER = address(SYSTEM_CONTRACTS_OFFSET + 0x07);
IL1Messenger constant L1_MESSENGER_CONTRACT = IL1Messenger(address(SYSTEM_CONTRACTS_OFFSET + 0x08));
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);

IEthToken constant ETH_TOKEN_SYSTEM_CONTRACT = IEthToken(address(SYSTEM_CONTRACTS_OFFSET + 0x0a));

address constant KECCAK256_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x10);

ISystemContext constant SYSTEM_CONTEXT_CONTRACT = ISystemContext(payable(address(SYSTEM_CONTRACTS_OFFSET + 0x0b)));

BootloaderUtilities constant BOOTLOADER_UTILITIES = BootloaderUtilities(address(SYSTEM_CONTRACTS_OFFSET + 0x0c));

address constant EVENT_WRITER_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x0d);

IBytecodeCompressor constant BYTECODE_COMPRESSOR_CONTRACT = IBytecodeCompressor(
    address(SYSTEM_CONTRACTS_OFFSET + 0x0e)
);

/// @dev If the bitwise AND of the extraAbi[2] param when calling the MSG_VALUE_SIMULATOR
/// is non-zero, the call will be assumed to be a system one.
uint256 constant MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT = 1;

/// @dev The maximal msg.value that context can have
uint256 constant MAX_MSG_VALUE = 2 ** 128 - 1;

/// @dev Prefix used during derivation of account addresses using CREATE2
/// @dev keccak256("zksyncCreate2")
bytes32 constant CREATE2_PREFIX = 0x2020dba91b30cc0006188af794c2fb30dd8520db7e2c088b7fc7c103c00ca494;
/// @dev Prefix used during derivation of account addresses using CREATE
/// @dev keccak256("zksyncCreate")
bytes32 constant CREATE_PREFIX = 0x63bae3a9951d38e8a3fbb7b70909afc1200610fc5bc55ade242f815974674f23;
