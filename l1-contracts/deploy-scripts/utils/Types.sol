// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

// solhint-disable-next-line gas-struct-packing
struct BridgehubDeployedAddresses {
    address bridgehubImplementation;
    address bridgehubProxy;
    address ctmDeploymentTrackerImplementation;
    address ctmDeploymentTrackerProxy;
    address messageRootImplementation;
    address messageRootProxy;
    address chainAssetHandlerImplementation;
    address chainAssetHandlerProxy;
    address interopCenterImplementation;
    address interopCenterProxy;
    address chainRegistrationSenderProxy;
    address chainRegistrationSenderImplementation;
    address assetTrackerProxy;
    address assetTrackerImplementation;
}

// solhint-disable-next-line gas-struct-packing
struct BridgesDeployedAddresses {
    address erc20BridgeImplementation;
    address erc20BridgeProxy;
    address l1AssetRouterImplementation;
    address l1AssetRouterProxy;
    address l1NullifierImplementation;
    address l1NullifierProxy;
    address bridgedStandardERC20Implementation;
    address bridgedTokenBeacon;
}

struct DataAvailabilityDeployedAddresses {
    address rollupDAManager;
    address l1RollupDAValidator;
    address noDAValidiumL1DAValidator;
    address availBridge;
    address availL1DAValidator;
    address l1BlobsDAValidatorZKsyncOS;
}

struct ZkChainAddresses {
    address governance;
    address diamondProxy;
    address chainAdmin;
    address l2LegacySharedBridge;
    address accessControlRestrictionAddress;
    address chainProxyAdmin;
}

// solhint-disable-next-line gas-struct-packing
struct StateTransitionDeployedAddresses {
    address chainTypeManagerProxy;
    address chainTypeManagerProxyAdmin;
    address chainTypeManagerImplementation;
    address verifier;
    address verifierFflonk;
    address verifierPlonk;
    address adminFacet;
    address mailboxFacet;
    address executorFacet;
    address gettersFacet;
    address diamondInit;
    address genesisUpgrade;
    address defaultUpgrade;
    address validatorTimelockImplementation;
    address validatorTimelock;
    address diamondProxy;
    address bytecodesSupplier;
    address serverNotifierProxy;
    address serverNotifierImplementation;
    address rollupDAManager;
    address rollupSLDAValidator;
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
    address permissionlessValidator;
}
