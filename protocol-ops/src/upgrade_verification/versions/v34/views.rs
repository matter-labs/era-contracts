//! Read-only views of the registry objects and the live contracts a v34 bootstrap
//! package touches.
//!
//! Declared inline rather than bound from `zkstack-out/` because the verifier needs a
//! handful of getters per object, not the objects' full ABIs, and because a package is
//! reviewed against a COMMIT: a getter list that lives here changes only when this
//! verifier changes, so a `zkstack-out` regeneration cannot silently move what a review
//! reads. `ICTMRelease` is the exception — it is already exported and bound as
//! `ICTMReleaseAbi`, so this module does not redeclare it.

use alloy::sol;

sol! {
    /// The bootstrap manifest, as stored in `RegistryBootstrapMigration`'s constructor.
    /// Field order and types mirror `RegistryTypes.sol` exactly — the decode is positional.
    #[derive(Debug)]
    struct ProxyUpgradeRow {
        address proxy;
        address expectedOldImpl;
        address implNew;
        bool callInitializeUpgrade;
        address admin;
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
        ProxyUpgradeRow[] proxyUpgrades;
        address currentRelease;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersionDeadline;
        address upgradeEngine;
        AuthoredL2Plan l2Plan;
        uint256 upgradeTimestamp;
        address ctmExecutor;
        address ctmExecutorOwner;
        address coordinator;
        address upgradeTimer;
    }

    #[sol(rpc)]
    contract RegistryBootstrapMigrationView {
        function executed() external view returns (bool);
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (BootstrapManifest memory);
        function validate() external view;
    }

    /// The object the edge's whole governance call sequence is derived from. The verifier reads
    /// the two objects it was built over, so the completion gate terminating stage 2 can be held
    /// against the edge the rest of the package describes.
    #[sol(rpc)]
    contract RegistryBootstrapSequenceView {
        function MIGRATION() external view returns (address);
        function CORE_REGISTRY() external view returns (address);
        function validateApplied() external view;
    }

    #[sol(rpc)]
    contract CTMUpgradeExecutorView {
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function CTM_PROXY_ADMIN() external view returns (address);
        function TRANSITION_CODEHASH() external view returns (bytes32);
        function coordinator() external view returns (address);
        function activeOperation() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
    }

    /// The lifecycle coordinator every later operation runs through.
    #[sol(rpc)]
    contract EcosystemUpgradeExecutorView {
        function CORE_EXECUTOR() external view returns (address);
        function ctmExecutor() external view returns (address);
        function setCTMExecutor(address _ctmExecutor) external;
        function OPERATION_CODEHASH() external view returns (bytes32);
        function pendingOperation() external view returns (address);
        function owner() external view returns (address);
    }

    /// The ecosystem-domain executor the shared `ProxyAdmin` lands under.
    #[sol(rpc)]
    contract CoreUpgradeExecutorView {
        function PROXY_ADMIN() external view returns (address);
        function CORE_REGISTRY_CODEHASH() external view returns (bytes32);
        function coordinator() external view returns (address);
        function owner() external view returns (address);
    }

    /// Positional mirror of `RegistryTypes.CoreRegistryManifest` — the whole constructor
    /// argument of a `CoreRegistry`, which is what its address commits to.
    #[derive(Debug)]
    struct CoreRegistryManifest {
        ProxyUpgradeRow[] proxyUpgrades;
    }

    #[sol(rpc)]
    contract CoreRegistryView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (CoreRegistryManifest memory);
        function ecosystemRows() external view returns (ProxyUpgradeRow[] memory);
        function validate() external view;
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
        bytes32 genesisBatchCommitment;
        uint64 genesisIndexRepeatedStorageChanges;
    }

    /// Positional mirror of `RegistryTypes.ReleaseManifest` — the whole constructor argument of
    /// a `CTMRelease`.
    #[derive(Debug)]
    struct ReleaseManifest {
        address diamondInit;
        address verifier;
        address genesisUpgrade;
        GenesisFacet[] genesisFacets;
        ReleaseGenesisData genesis;
        bytes[] l2BytecodeInfos;
        bytes l2SystemProxyBytecodeInfo;
    }

    /// The release's own reads, including the manifest its address commits to.
    #[sol(rpc)]
    contract CTMReleaseView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (ReleaseManifest memory);
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
    contract GovernanceUpgradeTimerView {
        function TIMER_GOVERNANCE() external view returns (address);
        function deadline() external view returns (uint256);
        function checkDeadline() external view;
    }

    #[sol(rpc)]
    contract ProxyAdminView {
        function owner() external view returns (address);
        function getProxyImplementation(address proxy) external view returns (address);
    }

    #[sol(rpc)]
    contract BytecodesSupplierView {
        function publishingBlock(bytes32 bytecodeHash) external view returns (uint256);
    }

    /// Only the hop from the CTM to its ChainAssetHandler, which the pause calls target.
    #[sol(rpc)]
    contract BridgehubForBootstrapView {
        function chainAssetHandler() external view returns (address);
    }

    #[sol(rpc)]
    contract CtmForBootstrapView {
        function protocolVersion() external view returns (uint256);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function currentRelease() external view returns (address);
        function releaseCodehash() external view returns (bytes32);
        function L1_BYTECODES_SUPPLIER() external view returns (address);
        function BRIDGE_HUB() external view returns (address);
    }
}
