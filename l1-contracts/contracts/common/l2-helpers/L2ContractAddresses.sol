// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

// solhint-disable-next-line no-unused-import
import {SYSTEM_CONTRACTS_OFFSET} from "system-contracts/contracts/Constants.sol";

/// @dev the offset for the system hooks for ZKsync OS
uint160 constant SYSTEM_HOOKS_OFFSET = 0x7000;

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant BUILT_IN_CONTRACTS_OFFSET = 0x10000; // 2^16

////////////////////////////////////////////////////////////
// zksync os system hooks
////////////////////////////////////////////////////////////

/// @dev The address of the L2ToL1Messenger system hook
address constant L1_MESSENGER_HOOK = address(SYSTEM_HOOKS_OFFSET + 0x01);

/// @dev The address of the system hook responsible for setting bytecode on address. Can only be called from L2_COMPLEX_UPGRADER address
address constant SET_BYTECODE_ON_ADDRESS_HOOK = address(SYSTEM_HOOKS_OFFSET + 0x02);

/// @dev The address of the system hook responsible for minting base tokens on ZK OS chains.
/// This hook can only be called from the L2_BASE_TOKEN_SYSTEM_CONTRACT (address 0x800A).
///
/// Usage: To mint base tokens, call the hook with the amount to mint encoded as uint256:
/// `(bool success, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(amountToMint));`
/// The hook will credit the caller (L2BaseToken contract) with the specified amount of native tokens.
/// After minting, the tokens can be transferred using Address.sendValue() or regular ETH transfers.
///
/// This hook is used during genesis/upgrade to initialize the BaseTokenHolder balance:
/// 1. L2BaseTokenZKOS.initializeBaseTokenHolderBalance() calls this hook to mint 2^127-1 tokens
/// 2. The minted tokens are then transferred to L2_BASE_TOKEN_HOLDER_ADDR
/// 3. This establishes the initial token supply invariant for the chain
///
/// Authorization:
/// - The hook validates that msg.sender is L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR (0x800A)
/// - L2BaseTokenZKOS restricts initializeBaseTokenHolderBalance() to L2_COMPLEX_UPGRADER_ADDR only
address constant MINT_BASE_TOKEN_HOOK = address(SYSTEM_HOOKS_OFFSET + 0x03);

////////////////////////////////////////////////////////////
// System contracts
////////////////////////////////////////////////////////////

/// @dev The maximum address of the built-in contracts.
uint160 constant MAX_BUILT_IN_CONTRACT_ADDR = BUILT_IN_CONTRACTS_OFFSET + 0x1ffff;

/// @dev The formal address of the initial program of the system: the bootloader
address constant L2_BOOTLOADER_ADDRESS = address(SYSTEM_CONTRACTS_OFFSET + 0x01);

/// @dev The address of the AccountCodeStorage system contract
address constant L2_ACCOUNT_CODE_STORAGE_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x02);

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

/// @dev The address of the L2ToL1Messenger system contract
address constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x08);

/// @dev the address of the msg value system contract
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);

/// @dev The address of the eth token system contract
address constant L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0a);

/// @dev The address of the context system contract
address constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0b);

/// @dev The address of the pubdata chunk publisher contract
address constant L2_PUBDATA_CHUNK_PUBLISHER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x11);

// @dev The address of the compressor contract.
address constant L2_COMPRESSOR_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0e);

/// @dev The address used to execute complex upgragedes, also used for the genesis upgrade
address constant L2_COMPLEX_UPGRADER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0f);

////////////////////////////////////////////////////////////
// Built-in contracts
////////////////////////////////////////////////////////////

/// @dev The address of the create2 factory contract
address constant L2_CREATE2_FACTORY_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x00);

/// @dev The address used to execute the genesis upgrade
address constant L2_GENESIS_UPGRADE_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x01);

/// @dev The genesis upgrade address is reused for all version specific upgrades
address constant L2_VERSION_SPECIFIC_UPGRADER_ADDR = L2_GENESIS_UPGRADE_ADDR;

/// @dev The address of the L2 bridge hub system contract, used to start L1->L2 transactions
address constant L2_BRIDGEHUB_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x02);

/// @dev the address of the l2 asset router.
address constant L2_ASSET_ROUTER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x03);

/// @dev An l2 system contract address, used in the assetId calculation for native assets.
/// This is needed for automatic bridging, i.e. without deploying the AssetHandler contract,
/// if the assetId can be calculated with this address then it is in fact an NTV asset
address constant L2_NATIVE_TOKEN_VAULT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x04);

/// @dev the address of the l2 message root.
address constant L2_MESSAGE_ROOT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x05);

/// @dev The address of the SloadContract system contract, which provides a method to read values from arbitrary storage slots
address constant SLOAD_CONTRACT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x06);

/// @dev The address of the l2 wrapped base token.
address constant L2_WRAPPED_BASE_TOKEN_IMPL_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x07);

/// @dev The address of the L2 interop root storage system contract
address constant L2_INTEROP_ROOT_STORAGE_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x08);

/// @dev The address of the L2 message verification system contract
address constant L2_MESSAGE_VERIFICATION_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x09);

/// @dev The address of the L2 chain handler system contract
address constant L2_CHAIN_ASSET_HANDLER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0a);

/// @dev UpgradeableBeaconDeployer that's responsible for deploying the upgradeable beacons for the bridged standard ERC20 tokens
/// @dev Besides separation of concerns, we need it as a separate contract to ensure that L2NativeTokenVaultZKOS
/// does not have to include BridgedStandardERC20 and UpgradeableBeacon and so can fit into the code size limit.
address constant L2_NTV_BEACON_DEPLOYER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0b);

/// @dev the address of the L2 system contract proxy admin
address constant L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0c);

/// @dev the address of the L2 interop center
address constant L2_INTEROP_CENTER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0d);

/// @dev the address of the L2 interop handler
address payable constant L2_INTEROP_HANDLER_ADDR = payable(address(BUILT_IN_CONTRACTS_OFFSET + 0x0e));

/// @dev the address of the L2 asset tracker
address constant L2_ASSET_TRACKER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0f);

/// @dev the address of the GW asset tracker
address constant GW_ASSET_TRACKER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x10);

/// @dev The address of the base token holder contract that holds chain's base token reserves.
address constant L2_BASE_TOKEN_HOLDER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x11);
