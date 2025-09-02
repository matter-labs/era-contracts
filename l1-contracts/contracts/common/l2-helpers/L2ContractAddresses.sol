// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL2ToL1Messenger} from "./IL2ToL1Messenger.sol";
import {IL2InteropRootStorage} from "../interfaces/IL2InteropRootStorage.sol";
import {IMessageVerification} from "../interfaces/IMessageVerification.sol";
import {IBaseToken} from "./IBaseToken.sol";
import {IL2ContractDeployer} from "../interfaces/IL2ContractDeployer.sol";
import {IL2NativeTokenVault} from "../../bridge/ntv/IL2NativeTokenVault.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";
import {IInteropCenter} from "../../interop/IInteropCenter.sol";
import {IL2AssetRouter} from "../../bridge/asset-router/IL2AssetRouter.sol";
import {IL2AssetTracker} from "../../bridge/asset-tracker/IL2AssetTracker.sol";
import {ISystemContext} from "../interfaces/ISystemContext.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";

/// @dev the offset for the system contracts
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant BUILT_IN_CONTRACTS_OFFSET = 0x10000; // 2^16

/// @dev The maximum address of the built-in contracts.
uint160 constant MAX_BUILT_IN_CONTRACT_ADDR = BUILT_IN_CONTRACTS_OFFSET + 0x1ffff;

/// @dev The formal address of the initial program of the system: the bootloader
address constant L2_BOOTLOADER_ADDRESS = address(SYSTEM_CONTRACTS_OFFSET + 0x01);

/// @dev The address of the known code storage system contract
address constant L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x04);

/// @dev The address of the L2 deployer system contract.
address constant L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x06);

IL2ContractDeployer constant L2_CONTRACT_DEPLOYER = IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);

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
/// @dev The address of the special smart contract that can send arbitrary length message as an L2 log
IL2ToL1Messenger constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT = IL2ToL1Messenger(
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
);

/// @dev the address of the msg value system contract
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);

/// @dev The address of the eth token system contract
address constant L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0a);
IBaseToken constant L2_BASE_TOKEN_SYSTEM_CONTRACT = IBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);

/// @dev The address of the context system contract
address constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0b);
ISystemContext constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT = ISystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);

/// @dev The address of the pubdata chunk publisher contract
address constant L2_PUBDATA_CHUNK_PUBLISHER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x11);

/// @dev The address used to execute complex upgragedes, also used for the genesis upgrade
address constant L2_COMPLEX_UPGRADER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0f);

/// @dev The address of the create2 factory contract
address constant L2_CREATE2_FACTORY_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x00);

/// @dev The address used to execute the genesis upgrade
address constant L2_GENESIS_UPGRADE_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x01);

/// @dev The genesis upgrade address is reused for all version specific upgrades
address constant L2_VERSION_SPECIFIC_UPGRADER_ADDR = L2_GENESIS_UPGRADE_ADDR;

/// @dev The address of the L2 bridge hub system contract, used to start L1->L2 transactions
address constant L2_BRIDGEHUB_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x02);

IBridgehub constant L2_BRIDGEHUB = IBridgehub(L2_BRIDGEHUB_ADDR);

/// @dev the address of the l2 asset router.
address constant L2_ASSET_ROUTER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x03);
IL2AssetRouter constant L2_ASSET_ROUTER = IL2AssetRouter(L2_ASSET_ROUTER_ADDR);

/// @dev An l2 system contract address, used in the assetId calculation for native assets.
/// This is needed for automatic bridging, i.e. without deploying the AssetHandler contract,
/// if the assetId can be calculated with this address then it is in fact an NTV asset
address constant L2_NATIVE_TOKEN_VAULT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x04);
IL2NativeTokenVault constant L2_NATIVE_TOKEN_VAULT = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

/// @dev the address of the l2 asset router.
address constant L2_MESSAGE_ROOT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x05);
IMessageRoot constant L2_MESSAGE_ROOT = IMessageRoot(L2_MESSAGE_ROOT_ADDR);

/// @dev The address of the SloadContract system contract, which provides a method to read values from arbitrary storage slots
address constant SLOAD_CONTRACT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x06);

/// @dev The address of the WETH implementation contract
address constant L2_WETH_IMPL_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x07);

/// @dev The address of the L2 interop root storage system contract
IL2InteropRootStorage constant L2_INTEROP_ROOT_STORAGE = IL2InteropRootStorage(
    address(BUILT_IN_CONTRACTS_OFFSET + 0x08)
);

/// @dev The address of the L2 message verification system contract
IMessageVerification constant L2_MESSAGE_VERIFICATION = IMessageVerification(address(BUILT_IN_CONTRACTS_OFFSET + 0x09));

/// @dev The address of the L2 chain handler system contract
address constant L2_CHAIN_ASSET_HANDLER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0a);
IChainAssetHandler constant L2_CHAIN_ASSET_HANDLER = IChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR);

/// @dev the address of the L2 interop center
address constant L2_INTEROP_CENTER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0b);
IInteropCenter constant L2_INTEROP_CENTER = IInteropCenter(L2_INTEROP_CENTER_ADDR);

/// @dev the address of the L2 interop handler
address constant L2_INTEROP_HANDLER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0c);

/// @dev the address of the L2 asset tracker
address constant L2_ASSET_TRACKER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0d);
IL2AssetTracker constant L2_ASSET_TRACKER = IL2AssetTracker(L2_ASSET_TRACKER_ADDR);
