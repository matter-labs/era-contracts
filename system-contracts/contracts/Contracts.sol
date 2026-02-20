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
import {SYSTEM_CONTRACTS_OFFSET, REAL_SYSTEM_CONTRACTS_OFFSET, MAX_SYSTEM_CONTRACT_ADDRESS, USER_CONTRACTS_OFFSET, ECRECOVER_SYSTEM_CONTRACT, SHA256_SYSTEM_CONTRACT, IDENTITY_SYSTEM_CONTRACT, MODEXP_SYSTEM_CONTRACT, ECADD_SYSTEM_CONTRACT, ECMUL_SYSTEM_CONTRACT, ECPAIRING_SYSTEM_CONTRACT, COMPUTATIONAL_PRICE_FOR_PUBDATA, CURRENT_MAX_PRECOMPILE_ADDRESS, BOOTLOADER_FORMAL_ADDRESS, FORCE_DEPLOYER, MSG_VALUE_SYSTEM_CONTRACT, EVENT_WRITER_CONTRACT, KECCAK256_SYSTEM_CONTRACT, CODE_ORACLE_SYSTEM_CONTRACT, EVM_GAS_MANAGER, EVM_PREDEPLOYS_MANAGER, L2_DA_VALIDATOR, L2_NATIVE_TOKEN_VAULT_ADDR, SLOAD_CONTRACT_ADDRESS, WRAPPED_BASE_TOKEN_IMPL_ADDRESS, L2_CHAIN_ASSET_HANDLER_ADDRESS, L2_UPGRADEABLE_BEACON_DEPLOYER_ADDRESS, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDRESS, L2_INTEROP_CENTER_ADDRESS, L2_INTEROP_HANDLER_ADDRESS, L2_ASSET_TRACKER_ADDRESS, GW_ASSET_TRACKER_ADDRESS, MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT, MAX_MSG_VALUE, CREATE2_PREFIX, CREATE_PREFIX, CREATE2_EVM_PREFIX, STATE_DIFF_ENTRY_SIZE, L2_TO_L1_LOG_SERIALIZE_SIZE, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, STATE_DIFF_COMPRESSION_VERSION_NUMBER, L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH, DERIVED_KEY_LENGTH, ENUM_INDEX_LENGTH, VALUE_LENGTH, COMPRESSED_INITIAL_WRITE_SIZE, COMPRESSED_REPEATED_WRITE_SIZE, INITIAL_WRITE_STARTING_POSITION, STATE_DIFF_DERIVED_KEY_OFFSET, STATE_DIFF_ENUM_INDEX_OFFSET, STATE_DIFF_FINAL_VALUE_OFFSET, BLOB_SIZE_BYTES, MAX_NUMBER_OF_BLOBS, ERA_VM_BYTECODE_FLAG, EVM_BYTECODE_FLAG, SERVICE_CALL_PSEUDO_CALLER, L2DACommitmentScheme, SUPPORTED_PROOF_METADATA_VERSION, HARD_CODED_CHAIN_ID} from "./Constants.sol";

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
