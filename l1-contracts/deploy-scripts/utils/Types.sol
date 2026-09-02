// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {
    Facets,
    Verifiers,
    StateTransitionContracts,
    StateTransitionDeployedAddresses,
    DAContracts
} from "contracts/common/StateTransitionTypes.sol";

/// @dev Value passed for the `eraChainId` parameter that several audited constructors and structs
/// still carry (`MailboxFacet`, `L1Nullifier`, `L1AssetRouter`,
/// `FixedForceDeploymentsData`, `GatewayCTMDeployerConfig`). Nothing this release deploys has an
/// Era chain, and `Bridgehub` rejects chain id 0 (`ZeroChainId`), so every Era-legacy branch keyed
/// off it is unreachable — whereas a made-up non-zero id would unlock those branches for whichever
/// chain happened to hold it.
uint256 constant ERA_CHAIN_ID_UNUSED = 0;

/// @dev Companion to {ERA_CHAIN_ID_UNUSED} for the `eraDiamondProxy` constructor parameter: with no
/// Era chain there is no Era diamond, and `msg.sender` can never be `address(0)`.
address constant ERA_DIAMOND_PROXY_UNUSED = address(0);

/// @dev First protocol version whose production verifier exports the testnet-verifier flag
/// (`isTestnetVerifier()`). Pre-v34 only testnet verifiers export it (as the legacy
/// `IS_TESTNET_VERIFIER` constant) and the production verifier reverts.
uint32 constant FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG = 34;

struct BridgehubContracts {
    address bridgehub;
    address messageRoot;
    address ctmDeploymentTracker;
    address chainAssetHandler;
    address chainRegistrationSender;
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

struct BridgeContracts {
    address l1AssetRouter;
    address l1Nullifier;
    address l1NativeTokenVault;
    address l1InteropHandler;
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

/// @notice L1-specific DA addresses that extend the shared `DAContracts`.
struct DataAvailabilityDeployedAddresses {
    DAContracts daContracts;
    address availBridge;
    address availL1DAValidator;
    address l1BlobsDAValidatorZKsyncOS;
}

/// @notice L1-specific state transition addresses that are not used in the Gateway context.
struct L1SpecificStateTransitionAddresses {
    address legacyValidatorTimelock;
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
    L1SpecificStateTransitionAddresses l1Specific;
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
}
