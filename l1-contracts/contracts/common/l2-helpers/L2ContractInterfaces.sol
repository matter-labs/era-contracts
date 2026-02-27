// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL2ToL1MessengerEra} from "./IL2ToL1MessengerEra.sol";
import {IL2InteropRootStorage} from "../../interop/IL2InteropRootStorage.sol";
import {IMessageVerification} from "../interfaces/IMessageVerification.sol";
import {IBaseToken} from "./IBaseToken.sol";
import {IL2ContractDeployer} from "../interfaces/IL2ContractDeployer.sol";
import {IL2NativeTokenVault} from "../../bridge/ntv/IL2NativeTokenVault.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../core/chain-asset-handler/IChainAssetHandler.sol";
import {IInteropCenter} from "../../interop/IInteropCenter.sol";
import {IInteropHandler} from "../../interop/IInteropHandler.sol";
import {IL2AssetRouter} from "../../bridge/asset-router/IL2AssetRouter.sol";
import {IL2AssetTracker} from "../../bridge/asset-tracker/IL2AssetTracker.sol";
import {IGWAssetTracker} from "../../bridge/asset-tracker/IGWAssetTracker.sol";
import {IBaseTokenHolder} from "../../l2-system/interfaces/IBaseTokenHolder.sol";
import {ISystemContext} from "../interfaces/ISystemContext.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";

// solhint-disable no-unused-import
import {
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_COMPRESSOR_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    GW_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    MAX_BUILT_IN_CONTRACT_ADDR,
    L2_BOOTLOADER_ADDRESS
} from "./L2ContractAddresses.sol";
// solhint-enable no-unused-import

/// @dev The address of the L2 deployer system contract.
IL2ContractDeployer constant L2_CONTRACT_DEPLOYER = IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);

/// @dev The address of the special smart contract that can send arbitrary length message as an L2 log
IL2ToL1MessengerEra constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT = IL2ToL1MessengerEra(
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
);

/// @dev The eth token system contract
IBaseToken constant L2_BASE_TOKEN_SYSTEM_CONTRACT = IBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);

/// @dev The system context system contract
ISystemContext constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT = ISystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);

/// @dev The L2 bridge hub system contract, used to start L1->L2 transactions
IBridgehubBase constant L2_BRIDGEHUB = IBridgehubBase(L2_BRIDGEHUB_ADDR);

/// @dev the l2 asset router.
IL2AssetRouter constant L2_ASSET_ROUTER = IL2AssetRouter(L2_ASSET_ROUTER_ADDR);

/// @dev An l2 system contract, used in the assetId calculation for native assets.
IL2NativeTokenVault constant L2_NATIVE_TOKEN_VAULT = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

/// @dev the l2 message root.
IMessageRootBase constant L2_MESSAGE_ROOT = IMessageRootBase(L2_MESSAGE_ROOT_ADDR);

/// @dev The L2 interop root storage system contract
IL2InteropRootStorage constant L2_INTEROP_ROOT_STORAGE = IL2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

/// @dev The L2 message verification system contract
IMessageVerification constant L2_MESSAGE_VERIFICATION = IMessageVerification(L2_MESSAGE_VERIFICATION_ADDR);

/// @dev The L2 chain handler system contract
IChainAssetHandlerBase constant L2_CHAIN_ASSET_HANDLER = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR);

/// @dev the L2 interop center
IInteropCenter constant L2_INTEROP_CENTER = IInteropCenter(L2_INTEROP_CENTER_ADDR);

/// @dev the L2 interop handler
IInteropHandler constant L2_INTEROP_HANDLER = IInteropHandler(L2_INTEROP_HANDLER_ADDR);

/// @dev the L2 asset tracker
IL2AssetTracker constant L2_ASSET_TRACKER = IL2AssetTracker(L2_ASSET_TRACKER_ADDR);

/// @dev the GW asset tracker
IGWAssetTracker constant GW_ASSET_TRACKER = IGWAssetTracker(GW_ASSET_TRACKER_ADDR);

/// @dev The base token holder contract that holds chain's base token reserves.
IBaseTokenHolder constant L2_BASE_TOKEN_HOLDER = IBaseTokenHolder(payable(L2_BASE_TOKEN_HOLDER_ADDR));
