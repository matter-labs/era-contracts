// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {Facets, Verifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

struct BridgehubContracts {
    address bridgehub;
    address messageRoot;
    address ctmDeploymentTracker;
    address chainAssetHandler;
    address chainRegistrationSender;
    address assetTracker;
}

struct BridgehubAddresses {
    BridgehubContracts proxies;
    BridgehubContracts implementations;
}

struct ZkChainAddresses {
    uint256 chainId;
    address zkChainProxy;
    address chainAdmin;
    address pendingChainAdmin;
    address chainTypeManager;
    address baseToken;
    address transactionFilterer;
    address settlementLayer;
    address l1DAValidator;
    L2DACommitmentScheme l2DAValidatorScheme;
    bytes32 baseTokenAssetId;
    address baseTokenAddress;
    address governance;
    address accessControlRestrictionAddress;
    address diamondProxy;
    address chainProxyAdmin;
    address l2LegacySharedBridge;
}

struct L2ERC20BridgeAddresses {
    address l2TokenBeacon;
    address l2Bridge;
    bytes32 l2TokenProxyBytecodeHash;
}

struct BridgeContracts {
    address erc20Bridge;
    address l1AssetRouter;
    address l1Nullifier;
    address l1NativeTokenVault;
}

// solhint-disable-next-line gas-struct-packing
struct BridgesDeployedAddresses {
    BridgeContracts proxies;
    BridgeContracts implementations;
    address bridgedStandardERC20Implementation;
    address bridgedTokenBeacon;
    address l1WethToken;
    bytes32 ethTokenAssetId;
}

struct L1CoreAdminAddresses {
    address transparentProxyAdmin;
    address governance;
    address bridgehubAdmin;
    address accessControlRestrictionAddress;
    address create2Factory;
}

// solhint-disable-next-line gas-struct-packing
struct CoreDeployedAddresses {
    BridgehubAddresses bridgehub;
    BridgesDeployedAddresses bridges;
    L1CoreAdminAddresses shared;
}

struct DataAvailabilityDeployedAddresses {
    address rollupDAManager;
    address l1RollupDAValidator;
    address noDAValidiumL1DAValidator;
    address availBridge;
    address availL1DAValidator;
    address l1BlobsDAValidatorZKsyncOS;
}

struct StateTransitionContracts {
    address chainTypeManager;
    address serverNotifier;
    address validatorTimelock;
}

// solhint-disable-next-line gas-struct-packing
struct StateTransitionDeployedAddresses {
    StateTransitionContracts proxies;
    StateTransitionContracts implementations;
    Verifiers verifiers;
    Facets facets;
    address genesisUpgrade;
    address defaultUpgrade;
    address legacyValidatorTimelock;
    address eraDiamondProxy;
    address bytecodesSupplier;
    address rollupDAManager;
    address rollupSLDAValidator;
}

struct CTMAdminAddresses {
    address transparentProxyAdmin;
    address governance;
    address accessControlRestrictionAddress;
    address eip7702Checker;
    address chainTypeManagerAdmin;
    address chainTypeManagerOwner;
}

struct CTMDeployedAddresses {
    StateTransitionDeployedAddresses stateTransition;
    DataAvailabilityDeployedAddresses daAddresses;
    CTMAdminAddresses admin;
    address chainAdmin;
}

struct ChainCreationParamsConfig {
    bytes32 genesisRoot;
    uint256 genesisRollupLeafIndex;
    bytes32 genesisBatchCommitment;
    // TODO probably move this to separate struct
    uint256 latestProtocolVersion;
    bytes32 bootloaderHash;
    bytes32 defaultAAHash;
    bytes32 evmEmulatorHash;
}
