// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {IAccountCodeStorage} from "./interfaces/IAccountCodeStorage.sol";
import {INonceHolder} from "./interfaces/INonceHolder.sol";
import {IContractDeployer} from "./interfaces/IContractDeployer.sol";
import {IKnownCodesStorage} from "./interfaces/IKnownCodesStorage.sol";
import {IImmutableSimulator} from "./interfaces/IImmutableSimulator.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {IBridgehub} from "./interfaces/IBridgehub.sol";
import {IL1Messenger} from "./interfaces/IL1Messenger.sol";
import {IMessageVerification} from "./interfaces/IMessageVerification.sol";
import {IChainAssetHandler} from "./interfaces/IChainAssetHandler.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {ICompressor} from "./interfaces/ICompressor.sol";
import {IComplexUpgrader} from "./interfaces/IComplexUpgrader.sol";
import {IBootloaderUtilities} from "./interfaces/IBootloaderUtilities.sol";
import {IPubdataChunkPublisher} from "./interfaces/IPubdataChunkPublisher.sol";
import {IMessageRoot} from "./interfaces/IMessageRoot.sol";
import {ICreate2Factory} from "./interfaces/ICreate2Factory.sol";
import {IEvmHashesStorage} from "./interfaces/IEvmHashesStorage.sol";
import {IL2AssetRouter} from "./interfaces/IL2AssetRouter.sol";
import {IL2AssetTracker} from "./interfaces/IL2AssetTracker.sol";
import {IGWAssetTracker} from "./interfaces/IGWAssetTracker.sol";
import {IL2NativeTokenVault} from "./interfaces/IL2NativeTokenVault.sol";
import {IL2InteropRootStorage} from "./interfaces/IL2InteropRootStorage.sol";

// Re-export all pure constants so consumers can import everything from this single file.
// solhint-disable-next-line no-unused-import
import {
    SYSTEM_CONTRACTS_OFFSET,
    REAL_SYSTEM_CONTRACTS_OFFSET,
  ,
    USER_CONTRACTS_OFFSET,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
    L2_NATIVE_TOKEN_VAULT_ADDR,
  ,
  ,
    L2_CHAIN_ASSET_HANDLER_ADDRESS,
  ,
  ,
  ,
  ,
    L2_ASSET_TRACKER_ADDRESS,
    GW_ASSET_TRACKER_ADDRESS,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  ,
  
} from "./Constants.sol";

IAccountCodeStorage constant ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT = IAccountCodeStorage(
    address(SYSTEM_CONTRACTS_OFFSET + 0x02)
);
INonceHolder constant NONCE_HOLDER_SYSTEM_CONTRACT = INonceHolder(address(SYSTEM_CONTRACTS_OFFSET + 0x03));
IKnownCodesStorage constant KNOWN_CODE_STORAGE_CONTRACT = IKnownCodesStorage(address(SYSTEM_CONTRACTS_OFFSET + 0x04));
IImmutableSimulator constant IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT = IImmutableSimulator(
    address(SYSTEM_CONTRACTS_OFFSET + 0x05)
);
IContractDeployer constant DEPLOYER_SYSTEM_CONTRACT = IContractDeployer(address(SYSTEM_CONTRACTS_OFFSET + 0x06));
IContractDeployer constant REAL_DEPLOYER_SYSTEM_CONTRACT = IContractDeployer(
    address(REAL_SYSTEM_CONTRACTS_OFFSET + 0x06)
);

IL1Messenger constant L1_MESSENGER_CONTRACT = IL1Messenger(address(SYSTEM_CONTRACTS_OFFSET + 0x08));

IBaseToken constant BASE_TOKEN_SYSTEM_CONTRACT = IBaseToken(address(SYSTEM_CONTRACTS_OFFSET + 0x0a));
IBaseToken constant REAL_BASE_TOKEN_SYSTEM_CONTRACT = IBaseToken(address(REAL_SYSTEM_CONTRACTS_OFFSET + 0x0a));

ISystemContext constant SYSTEM_CONTEXT_CONTRACT = ISystemContext(payable(address(SYSTEM_CONTRACTS_OFFSET + 0x0b)));
ISystemContext constant REAL_SYSTEM_CONTEXT_CONTRACT = ISystemContext(
    payable(address(REAL_SYSTEM_CONTRACTS_OFFSET + 0x0b))
);

IBootloaderUtilities constant BOOTLOADER_UTILITIES = IBootloaderUtilities(address(SYSTEM_CONTRACTS_OFFSET + 0x0c));

ICompressor constant COMPRESSOR_CONTRACT = ICompressor(address(SYSTEM_CONTRACTS_OFFSET + 0x0e));

IComplexUpgrader constant COMPLEX_UPGRADER_CONTRACT = IComplexUpgrader(address(SYSTEM_CONTRACTS_OFFSET + 0x0f));

IPubdataChunkPublisher constant PUBDATA_CHUNK_PUBLISHER = IPubdataChunkPublisher(
    address(SYSTEM_CONTRACTS_OFFSET + 0x11)
);

IEvmHashesStorage constant EVM_HASHES_STORAGE = IEvmHashesStorage(address(SYSTEM_CONTRACTS_OFFSET + 0x15));

ICreate2Factory constant L2_CREATE2_FACTORY = ICreate2Factory(address(USER_CONTRACTS_OFFSET));
IL2AssetRouter constant L2_ASSET_ROUTER = IL2AssetRouter(address(USER_CONTRACTS_OFFSET + 0x03));
IBridgehub constant L2_BRIDGE_HUB = IBridgehub(address(USER_CONTRACTS_OFFSET + 0x02));
IL2NativeTokenVault constant L2_NATIVE_TOKEN_VAULT = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
IMessageRoot constant L2_MESSAGE_ROOT = IMessageRoot(address(USER_CONTRACTS_OFFSET + 0x05));

IL2InteropRootStorage constant L2_INTEROP_ROOT_STORAGE = IL2InteropRootStorage(address(USER_CONTRACTS_OFFSET + 0x08));
IMessageVerification constant L2_MESSAGE_VERIFICATION = IMessageVerification(address(USER_CONTRACTS_OFFSET + 0x09));
IChainAssetHandler constant L2_CHAIN_ASSET_HANDLER = IChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDRESS);
IL2AssetTracker constant L2_ASSET_TRACKER = IL2AssetTracker(address(L2_ASSET_TRACKER_ADDRESS));
IGWAssetTracker constant GW_ASSET_TRACKER = IGWAssetTracker(address(GW_ASSET_TRACKER_ADDRESS));
