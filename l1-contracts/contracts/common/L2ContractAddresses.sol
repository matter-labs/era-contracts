// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev the offset for the system contracts
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant USER_CONTRACTS_OFFSET = 0x10000; // 2^16

/// @dev The formal address of the initial program of the system: the bootloader
address constant L2_BOOTLOADER_ADDRESS = address(SYSTEM_CONTRACTS_OFFSET + 0x01);

/// @dev The address of the known code storage system contract
address constant L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x04);

/// @dev The address of the L2 deployer system contract.
address constant L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x06);

/// @dev The special reserved L2 address. It is located in the system contracts space but doesn't have deployed
/// bytecode.
/// @dev The L2 deployer system contract allows changing bytecodes on any address if the `msg.sender` is this address.
/// @dev So, whenever the governor wants to redeploy system contracts, it just initiates the L1 upgrade call deployer
/// system contract
/// via the L1 -> L2 transaction with `sender == L2_FORCE_DEPLOYER_ADDR`. For more details see the
/// `diamond-initializers` contracts.
address constant L2_FORCE_DEPLOYER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x07);

/// @dev The address of the special smart contract that can send arbitrary length message as an L2 log
IL2ToL1Messenger constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR = IL2ToL1Messenger(
    address(SYSTEM_CONTRACTS_OFFSET + 0x08)
);

/// @dev The address of the eth token system contract
address constant L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0a);

/// @dev The address of the context system contract
address constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0b);

/// @dev The address of the pubdata chunk publisher contract
address constant L2_PUBDATA_CHUNK_PUBLISHER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x11);

/// @dev The address used to execute complex upgragedes, also used for the genesis upgrade
address constant L2_COMPLEX_UPGRADER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0f);

/// @dev the address of the msg value system contract
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);

/// @dev The address used to execute the genesis upgrade
address constant L2_GENESIS_UPGRADE_ADDR = address(USER_CONTRACTS_OFFSET + 0x01);

/// @dev The address of the L2 bridge hub system contract, used to start L1->L2 transactions
address constant L2_BRIDGEHUB_ADDR = address(USER_CONTRACTS_OFFSET + 0x02);

/// @dev the address of the l2 asset router.
address constant L2_ASSET_ROUTER_ADDR = address(USER_CONTRACTS_OFFSET + 0x03);

/// @dev An l2 system contract address, used in the assetId calculation for native assets.
/// This is needed for automatic bridging, i.e. without deploying the AssetHandler contract,
/// if the assetId can be calculated with this address then it is in fact an NTV asset
address constant L2_NATIVE_TOKEN_VAULT_ADDR = address(USER_CONTRACTS_OFFSET + 0x04);

/// @dev the address of the l2 asset router.
address constant L2_MESSAGE_ROOT_ADDR = address(USER_CONTRACTS_OFFSET + 0x05);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed-length messages on L1.
 * A fixed length message has 4 parameters `senderAddress`, `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable-length message we use this trick:
 * - This system contract accepts an arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `isService == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
interface IL2ToL1Messenger {
    /// @notice Sends an arbitrary length message to L1.
    /// @param _message The variable length message to be sent to L1.
    /// @return Returns the keccak256 hashed value of the message.
    function sendToL1(bytes calldata _message) external returns (bytes32);
}
