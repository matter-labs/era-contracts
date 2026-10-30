//! Read-only views of the registry objects and the live contracts a package touches — an
//! ordinary upgrade's executor legs, the one-time bootstrap edge, or a transition replacement.
//!
//! Declared inline rather than bound from `zkstack-out/` because the verifier needs a
//! handful of getters per object, not the objects' full ABIs, and because a package is
//! reviewed against a COMMIT: a getter list that lives here changes only when this
//! verifier changes, so a `zkstack-out` regeneration cannot silently move what a review
//! reads. `ICTMRelease` is the exception — it is already exported and bound as
//! `ICTMReleaseAbi`, so this module does not redeclare it.

use alloy::sol;

sol! {
    /// Positional mirror of `RegistryTypes.ProxyUpgradeRow`. It names no admin: a row is always
    /// read and applied through the applying domain's bound `ProxyAdmin`.
    #[derive(Debug)]
    struct ProxyUpgradeRow {
        address proxy;
        address expectedOldImpl;
        address implNew;
        bool callInitializeUpgrade;
    }

    /// The authored L2 input only: the object constructs the deployments, the delegate
    /// target and the factory dependencies from these at construction.
    #[derive(Debug)]
    struct AuthoredL2Plan {
        bytes delegateBytecodeInfo;
        bytes[] extraBytecodeInfos;
        address delegateComposer;
    }

    /// Positional mirror of `RegistryTypes.BootstrapManifest`. Every field a reviewer must
    /// agree to is here, so the verifier reads the committed manifest itself rather than the
    /// prepare's summary of it.
    #[derive(Debug)]
    struct BootstrapManifest {
        address ctm;
        uint256 expectedProtocolVersion;
        address ctmProxyAdmin;
        ProxyUpgradeRow[] ctmProxyUpgrades;
        address currentRelease;
        uint256 oldProtocolVersionDeadline;
        address upgradeEngine;
        AuthoredL2Plan l2Plan;
        uint256 upgradeTimestamp;
        address ctmExecutor;
        address coreExecutor;
        address governance;
    }

    #[sol(rpc)]
    contract RegistryBootstrapMigrationView {
        function executed() external view returns (bool);
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (BootstrapManifest memory);
        /// The version the edge lands on: its genesis release's own, read at construction.
        function newProtocolVersion() external view returns (uint256);
        function validate() external view;
        /// The edge's completion check, the bootstrap bundle's last call.
        function validateApplied() external view;
    }

    /// One governance call of a bootstrap edge, as `RegistryBootstrapSequence` derives it.
    #[derive(Debug)]
    struct BootstrapAction {
        string label;
        string authority;
        BootstrapCall call;
    }

    /// Positional mirror of `governance/Common.sol`'s `Call`, under a distinct name so it cannot
    /// collide with the tool's own decoded governance call type.
    #[derive(Debug)]
    struct BootstrapCall {
        address target;
        uint256 value;
        bytes data;
    }

    /// The object the edge's governance bundle is derived from: the verifier reads its one list,
    /// so the submitted bundle can be compared against the list the contract itself derives.
    #[sol(rpc)]
    contract RegistryBootstrapSequenceView {
        function actions() external view returns (BootstrapAction[] memory);
    }

    /// The CTM domain's executor. `forward` is declared so the verifier can ENCODE the owner-gated
    /// call through which governance acts on the CTM domain (the bootstrap's ServerNotifier
    /// acceptance, a replacement's `replaceUpgradeTransition`); the two `apply*` entrypoints so it
    /// can independently re-encode an upgrade's CTM legs and compare them byte for byte.
    #[sol(rpc)]
    contract CTMUpgradeExecutorView {
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function CTM_PROXY_ADMIN() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function forward(BootstrapCall[] calldata _calls) external payable;
        function applyInfrastructureUpgrade(address _infrastructureTransition) external;
        function applyCTMUpgrade(address _transition) external;
    }

    /// The CTM's ServerNotifier, whose administration and ownership the bootstrap requires
    /// handed to the CTM domain. `acceptOwnership` is declared to ENCODE the bundle call that
    /// completes that handover.
    #[sol(rpc)]
    contract ServerNotifierView {
        function chainTypeManager() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function acceptOwnership() external;
    }

    /// Positional mirror of `RegistryTypes.TransitionManifest` — the whole constructor argument of
    /// a `CTMTransition`. The version edge is not in it: the object reads it off its two releases.
    #[derive(Debug)]
    struct TransitionManifest {
        address fromRelease;
        address newRelease;
        address upgradeEngine;
        uint256 oldProtocolVersionDeadline;
        uint256 upgradeTimestamp;
        AuthoredL2Plan l2Plan;
    }

    /// Positional mirror of `Diamond.FacetCut`, with `Action` as its underlying `uint8`.
    #[derive(Debug)]
    struct FacetCut {
        address facet;
        uint8 action;
        bool isFreezable;
        bytes4[] selectors;
    }

    /// The chain-version edge an upgrade's transition leg applies.
    ///
    /// `facetCuts()` is DERIVED at construction from the release pair — the state a counterfeit
    /// exists to replace, and what every chain applies verbatim through delegatecall — so it is
    /// rendered for the reviewer rather than only counted.
    #[sol(rpc)]
    contract CTMTransitionView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (TransitionManifest memory);
        function oldProtocolVersion() external view returns (uint256);
        function newProtocolVersion() external view returns (uint256);
        function fromRelease() external view returns (address);
        function newRelease() external view returns (address);
        function oldProtocolVersionDeadline() external view returns (uint256);
        function facetCuts() external view returns (FacetCut[] memory);
        function validate() external view;
    }

    /// The ecosystem-domain executor the shared `ProxyAdmin` lands under. `applyL1Upgrade` is
    /// declared so the verifier can independently re-encode an upgrade's core leg.
    #[sol(rpc)]
    contract CoreUpgradeExecutorView {
        function PROXY_ADMIN() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function applyL1Upgrade(address _coreTransition) external;
    }

    /// Positional mirror of `RegistryTypes.ProxyUpgradeTransitionManifest` — the whole
    /// constructor argument of a `ProxyUpgradeTransition`, which is what its address commits to.
    /// `domain` is the `ProxyUpgradeDomain` enum as its underlying `uint8`
    /// ([`crate::upgrade_verification::constants::PROXY_UPGRADE_DOMAIN_CORE`] /
    /// [`crate::upgrade_verification::constants::PROXY_UPGRADE_DOMAIN_CTM`]).
    #[derive(Debug)]
    struct ProxyUpgradeTransitionManifest {
        uint8 domain;
        ProxyUpgradeRow[] proxyUpgrades;
    }

    /// One domain's write-once proxy inventory: the core leg's (`Core`) or the CTM
    /// infrastructure leg's (`CTM`).
    #[sol(rpc)]
    contract ProxyUpgradeTransitionView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (ProxyUpgradeTransitionManifest memory);
        function domain() external view returns (uint8);
        function rows() external view returns (ProxyUpgradeRow[] memory);
    }

    /// The live owner and outstanding nomination of an `Ownable2Step` contract, and the call
    /// through which the nominee takes it.
    #[sol(rpc)]
    contract Ownable2StepView {
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function acceptOwnership() external;
    }

    /// Positional mirror of `RegistryTypes.GenesisFacet`.
    #[derive(Debug)]
    struct GenesisFacet {
        address facet;
        bool isFreezable;
    }

    /// Positional mirror of `RegistryTypes.ReleaseGenesisData`.
    #[derive(Debug)]
    struct ReleaseGenesisData {
        bytes fixedForceDeploymentsData;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
    }

    /// Positional mirror of `RegistryTypes.ReleaseManifest` — the whole constructor argument of
    /// a `CTMRelease`.
    #[derive(Debug)]
    struct ReleaseManifest {
        uint256 protocolVersion;
        address diamondInit;
        address verifier;
        address genesisUpgrade;
        GenesisFacet[] genesisFacets;
        ReleaseGenesisData genesis;
        bytes[] l2BytecodeInfos;
        bytes l2SystemProxyBytecodeInfo;
    }

    /// The release's own reads, including the manifest its address commits to. `validate()` is
    /// state-independent, so its `eth_call` before the vote predicts the install; the errors are
    /// the ones it reverts with.
    #[sol(rpc)]
    contract CTMReleaseView {
        error RegistryTargetHasNoCode(address target);
        error RegistryEmptySelectors(address facet);
        error RegistryDuplicateSelector(bytes4 selector);

        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (ReleaseManifest memory);
        function protocolVersion() external view returns (uint256);
        function validate() external view;
    }

    /// One force deployment of a composed L2 plan — `IComplexUpgrader`'s shape, mirrored so the
    /// derived payload can be rendered for review.
    #[derive(Debug)]
    struct UniversalContractUpgradeInfo {
        uint8 upgradeType;
        bytes deployedBytecodeInfo;
        address newAddress;
    }

    /// The FINAL L2 plan an object constructed at its own construction — derived state, so it is
    /// exactly what a counterfeit would tamper with and what a reviewer must see.
    #[derive(Debug)]
    struct L2UpgradePlan {
        UniversalContractUpgradeInfo[] deployments;
        address delegateTo;
        address delegateComposer;
        uint256[] factoryDepHashes;
    }

    /// The derived payloads every committed object serves.
    #[sol(rpc)]
    contract CommittedUpgradeView {
        function l2Plan() external view returns (L2UpgradePlan memory);
        function upgradeTarget() external view returns (uint256, uint256, address);
    }

    #[sol(rpc)]
    contract ProxyAdminView {
        function owner() external view returns (address);
        function getProxyImplementation(address proxy) external view returns (address);
    }

    /// The CTM's bytecode supplier. `evmPublishingBlock` is the exact read
    /// `L2PlanLib.requirePublished` performs when the CTM commits a transition (and the bootstrap
    /// migration's `validate()`), so a zero here is the readiness failure that would revert it.
    /// The event carries the published code.
    #[sol(rpc)]
    contract BytecodesSupplierView {
        event EVMBytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);
        function evmPublishingBlock(bytes32 bytecodeHash) external view returns (uint256);
    }

    /// The chain registry the bootstrap's lagging-chain report enumerates, the CTM registry every
    /// CTM a package drives must be in, the live values a release's force deployments are held
    /// against, the ecosystem proxies an inventory's slots must name, and the owner a CTM also
    /// takes its chain freezes from.
    #[sol(rpc)]
    contract BridgehubView {
        function owner() external view returns (address);
        function chainTypeManagerIsRegistered(address _chainTypeManager) external view returns (bool);
        function getAllZKChainChainIDs() external view returns (uint256[] memory);
        function chainTypeManager(uint256 _chainId) external view returns (address);
        function assetRouter() external view returns (address);
        function MAX_NUMBER_OF_ZK_CHAINS() external view returns (uint256);
        function chainRegistrationSender() external view returns (address);
        function messageRoot() external view returns (address);
        function l1CtmDeployer() external view returns (address);
        function chainAssetHandler() external view returns (address);
        function getZKChain(uint256 _chainId) external view returns (address);
    }

    /// A chain's diamond, for the verifier its chain runs today and the RollupDAManager its Admin
    /// facet was built over.
    #[sol(rpc)]
    contract ZkChainGettersView {
        function getVerifier() external view returns (address);
        function getRollupDAManager() external view returns (address);
    }

    /// The asset router's links to the nullifier and the native token vault, which an ecosystem
    /// inventory's slots must name, and the WETH token and owner new ecosystem implementations
    /// are built with.
    #[sol(rpc)]
    contract L1AssetRouterView {
        function L1_NULLIFIER() external view returns (address);
        function nativeTokenVault() external view returns (address);
        function L1_WETH_TOKEN() external view returns (address);
        function owner() external view returns (address);
    }

    /// The nullifier's link to the interop handler, which an ecosystem inventory's slot must name.
    #[sol(rpc)]
    contract L1NullifierView {
        function l1InteropHandler() external view returns (address);
    }

    /// The sub-verifier getters of the verifier contracts. Each verifier answers only the ones its
    /// own contract declares; which ones those are is read off the artifact it was identified as.
    #[sol(rpc)]
    contract VerifierTreeView {
        function INNER_VERIFIER() external view returns (address);
        function AIRBENDER_VERIFIER() external view returns (address);
        function ZISK_RANGE_VERIFIER() external view returns (address);
        function PLONK_VERIFIER() external view returns (address);
    }

    /// Positional mirror of `IL2GenesisUpgrade.FixedForceDeploymentsData` — what a release's
    /// `fixedForceDeploymentsData` decodes as.
    #[derive(Debug)]
    struct FixedForceDeploymentsData {
        uint256 l1ChainId;
        address l1AssetRouter;
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

    /// `replaceUpgradeTransition` and `setProtocolVersionDeadline` are declared to DECODE the calls
    /// a replacement package forwards to the CTM.
    #[sol(rpc)]
    contract CtmView {
        function protocolVersion() external view returns (uint256);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function currentRelease() external view returns (address);
        function L1_BYTECODES_SUPPLIER() external view returns (address);
        function L1_INTEROP_FEE_MANAGER() external view returns (address);
        function BRIDGE_HUB() external view returns (address);
        function serverNotifierAddress() external view returns (address);
        function validatorTimelockPostV29() external view returns (address);
        function PERMISSIONLESS_VALIDATOR() external view returns (address);
        function getProtocolVersion(uint256 _chainId) external view returns (uint256);
        function upgradeTransition(uint256 _oldProtocolVersion) external view returns (address);
        function protocolVersionDeadline(uint256 _protocolVersion) external view returns (uint256);
        function replaceUpgradeTransition(address _expectedTransition, address _replacement) external;
        function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external;
    }
}
