//! Typed views over the deployed ecosystem.
//!
//! Deliberately narrow: only the getters the verifier reads, grouped by the
//! contract they live on, so overloaded names across contracts (`bridgehub
//! .chainTypeManager(uint256)` vs `serverNotifier.chainTypeManager()`) do not
//! collapse into generated `_0` / `_1` suffixes.

// This module is nothing but `sol!`-generated bindings; the generated
// `NewChainCreationParams` constructor takes one argument per event field.
#![allow(clippy::too_many_arguments)]

use alloy::sol;

sol! {
    #[sol(rpc)]
    interface IBridgehubView {
        function owner() external view returns (address);
        function admin() external view returns (address);
        function assetRouter() external view returns (address);
        function chainAssetHandler() external view returns (address);
        function l1CtmDeployer() external view returns (address);
        function messageRoot() external view returns (address);
        function chainRegistrationSender() external view returns (address);
        function L1_CHAIN_ID() external view returns (uint256);
        function MAX_NUMBER_OF_ZK_CHAINS() external view returns (uint256);
        function getAllZKChainChainIDs() external view returns (uint256[] memory);
        function getZKChain(uint256 chainId) external view returns (address);
        function chainTypeManagerIsRegistered(address ctm) external view returns (bool);
        function assetIdIsRegistered(bytes32 assetId) external view returns (bool);
        function ctmAssetIdFromAddress(address ctm) external view returns (bytes32);
        function ctmAssetIdToAddress(bytes32 assetId) external view returns (address);
        function whitelistedSettlementLayers(uint256 chainId) external view returns (bool);
        function baseTokenAssetId(uint256 chainId) external view returns (bytes32);
        function settlementLayer(uint256 chainId) external view returns (uint256);
    }

    #[sol(rpc)]
    interface ICtmView {
        function protocolVersion() external view returns (uint256);
        function getSemverProtocolVersion() external view returns (uint32, uint32, uint32);
        function storedBatchZero() external view returns (bytes32);
        function initialCutHash() external view returns (bytes32);
        function initialForceDeploymentHash() external view returns (bytes32);
        function l1GenesisUpgrade() external view returns (address);
        function defaultUpgrade() external view returns (address);
        function serverNotifierAddress() external view returns (address);
        function validatorTimelockPostV29() external view returns (address);
        function protocolVersionVerifier(uint256 protocolVersion) external view returns (address);
        function protocolVersionDeadline(uint256 protocolVersion) external view returns (uint256);
        function isZKsyncOS() external view returns (bool);
        function BRIDGE_HUB() external view returns (address);
        function INTEROP_CENTER() external view returns (address);
        function L1_BYTECODES_SUPPLIER() external view returns (address);
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
        function getChainAdmin(uint256 chainId) external view returns (address);
    }

    #[sol(rpc)]
    interface IAssetRouterView {
        function nativeTokenVault() external view returns (address);
        function L1_NULLIFIER() external view returns (address);
        function l1InteropHandler() external view returns (address);
        function L1_WETH_TOKEN() external view returns (address);
        function ERA_CHAIN_ID() external view returns (uint256);
        function ERA_DIAMOND_PROXY() external view returns (address);
        function ETH_TOKEN_ASSET_ID() external view returns (bytes32);
        function assetHandlerAddress(bytes32 assetId) external view returns (address);
    }

    #[sol(rpc)]
    interface INativeTokenVaultView {
        function bridgedTokenBeacon() external view returns (address);
        function WETH_TOKEN() external view returns (address);
        function tokenAddress(bytes32 assetId) external view returns (address);
    }

    #[sol(rpc)]
    interface INullifierView {
        function l1AssetRouter() external view returns (address);
        function l1NativeTokenVault() external view returns (address);
        function l1InteropHandler() external view returns (address);
    }

    #[sol(rpc)]
    interface IChainAssetHandlerView {
        function MESSAGE_ROOT() external view returns (address);
        function ASSET_ROUTER() external view returns (address);
    }

    #[sol(rpc)]
    interface IVerifierView {
        function PLONK_VERIFIER() external view returns (address);
        function verificationKeyHash() external view returns (bytes32);
        function IS_TESTNET_VERIFIER() external view returns (bool);
    }

    #[sol(rpc)]
    interface IServerNotifierView {
        function chainTypeManager() external view returns (address);
    }

    #[sol(rpc)]
    interface IRollupDAManagerView {
        function isPairAllowed(address l1DAValidator, uint8 l2Scheme) external view returns (bool);
    }

    #[sol(rpc)]
    interface ITimelockView {
        function executionDelay() external view returns (uint32);
        function sharedValidatorsCount() external view returns (uint256);
        function sharedSigningThreshold() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IGovernanceView {
        function securityCouncil() external view returns (address);
        function minDelay() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IChainAdminView {
        function tokenMultiplierSetter() external view returns (address);
    }

    #[sol(rpc)]
    interface IBeaconView {
        function implementation() external view returns (address);
    }

    #[sol(rpc)]
    interface IZKChainView {
        function getDAValidatorPair() external view returns (address, uint8);
        function getBaseTokenAssetId() external view returns (bytes32);
        function getVerifier() external view returns (address);
        function getProtocolVersion() external view returns (uint256);
        function getAdmin() external view returns (address);
        function storedBatchHash(uint256 batchNumber) external view returns (bytes32);
        function facetAddresses() external view returns (address[] memory);
    }

    #[sol(rpc)]
    interface IOwnableView {
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
    }

    /// Events read from logs, for state the contracts keep private.
    interface IEcosystemEvents {
        event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);
        event NewChainCreationParams(
            address genesisUpgrade,
            bytes32 genesisBatchHash,
            uint64 genesisIndexRepeatedStorageChanges,
            bytes32 genesisBatchCommitment,
            DiamondCutData newInitialCut,
            bytes32 newInitialCutHash,
            bytes forceDeploymentsData,
            bytes32 forceDeploymentHash
        );
        event DAPairUpdated(address indexed l1DAValidator, uint8 indexed l2Scheme, bool status);
    }

    struct FacetCut {
        address facet;
        uint8 action;
        bool isFreezable;
        bytes4[] selectors;
    }

    struct DiamondCutData {
        FacetCut[] facetCuts;
        address initAddress;
        bytes initCalldata;
    }

    /// `IL2GenesisUpgrade.FixedForceDeploymentsData`, decoded from the
    /// `forceDeploymentsData` blob in the chain creation params.
    struct FixedForceDeploymentsData {
        uint256 l1ChainId;
        uint256 eraChainId;
        address l1AssetRouter;
        bytes32 l2TokenProxyBytecodeHash;
        address aliasedL1Governance;
        uint256 maxNumberOfZKChains;
        bytes bridgehubBytecodeInfo;
        bytes l2AssetRouterBytecodeInfo;
        bytes l2NtvBytecodeInfo;
        bytes messageRootBytecodeInfo;
        bytes chainAssetHandlerBytecodeInfo;
        bytes interopCenterBytecodeInfo;
        bytes interopHandlerBytecodeInfo;
        bytes assetTrackerBytecodeInfo;
        bytes beaconDeployerInfo;
        bytes baseTokenHolderBytecodeInfo;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
        address aliasedChainRegistrationSender;
        address dangerousTestOnlyForcedBeacon;
        bytes32 zkTokenAssetId;
    }

    /// `IExecutor.StoredBatchInfo`, hashed into `ChainTypeManagerBase.storedBatchZero`.
    struct StoredBatchInfo {
        uint64 batchNumber;
        bytes32 batchHash;
        uint64 indexRepeatedStorageChanges;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 dependencyRootsRollingHash;
        bytes32 l2LogsTreeRoot;
        uint256 timestamp;
        bytes32 commitment;
    }
}
