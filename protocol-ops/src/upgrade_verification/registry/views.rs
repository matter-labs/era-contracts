//! Read-only views of the registry objects and the live contracts a package touches — an
//! ordinary recurring operation, or the one-time bootstrap edge.
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

    /// The object the edge's whole governance call sequence is derived from. The verifier reads
    /// the two objects it was built over, so the completion gate terminating stage 2 can be held
    /// against the edge the rest of the package describes, and the three stage lists, so the
    /// submitted bundle can be compared against the list the contract itself derives.
    #[sol(rpc)]
    contract RegistryBootstrapSequenceView {
        function MIGRATION() external view returns (address);
        function CORE_REGISTRY() external view returns (address);
        function stage0Actions() external view returns (BootstrapAction[] memory);
        function stage1Actions() external view returns (BootstrapAction[] memory);
        function stage2Actions() external view returns (BootstrapAction[] memory);
        function validateApplied() external view;
    }

    #[sol(rpc)]
    contract CTMUpgradeExecutorView {
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function CTM_PROXY_ADMIN() external view returns (address);
        function coordinator() external view returns (address);
        function activeOperation() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
    }

    /// The lifecycle coordinator every later operation runs through.
    ///
    /// `stage0`/`stage1`/`stage2` are declared so the verifier can ENCODE the three calls a
    /// recurring upgrade's governance transaction must contain and compare them byte for byte —
    /// the whole of "does the signed transaction invoke the reviewed upgrade at the intended
    /// address?" for an ordinary operation.
    #[sol(rpc)]
    contract EcosystemUpgradeExecutorView {
        function CORE_EXECUTOR() external view returns (address);
        function ctmExecutor() external view returns (address);
        function setCTMExecutor(address _ctmExecutor) external;
        function pendingOperation() external view returns (address);
        function pendingStage() external view returns (uint8);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function stage0(address _operation) external;
        function stage1(address _operation) external;
        function stage2(address _operation) external;
    }

    /// Positional mirror of `RegistryTypes.OperationManifest` — the whole constructor argument of
    /// an `EcosystemUpgradeOperation`, and therefore what its address commits to.
    #[derive(Debug)]
    struct OperationManifest {
        address coreRegistry;
        ProxyUpgradeRow[] ctmInfrastructure;
        address transition;
        address timer;
    }

    /// The operation object a recurring upgrade's three governance calls name.
    #[sol(rpc)]
    contract EcosystemUpgradeOperationView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (OperationManifest memory);
        function ctmInfrastructureRows() external view returns (ProxyUpgradeRow[] memory);
        function validate() external view;
    }

    /// Positional mirror of `RegistryTypes.TransitionManifest` — the whole constructor argument of
    /// a `CTMTransition`.
    #[derive(Debug)]
    struct TransitionManifest {
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
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

    /// The chain-version edge an operation may carry.
    ///
    /// `facetCuts()` is DERIVED at construction from the release pair — the state a counterfeit
    /// exists to replace, and what every chain applies verbatim through delegatecall — so it is
    /// rendered for the reviewer rather than only counted.
    #[sol(rpc)]
    contract CTMTransitionView {
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (TransitionManifest memory);
        function facetCuts() external view returns (FacetCut[] memory);
        function validate() external view;
    }

    /// The ecosystem-domain executor the shared `ProxyAdmin` lands under.
    #[sol(rpc)]
    contract CoreUpgradeExecutorView {
        function PROXY_ADMIN() external view returns (address);
        function coordinator() external view returns (address);
        function activeOperation() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
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

    /// The timer's constructor-set values are read back only to NAME which argument a failed
    /// construction check disagrees on; the check itself re-derives the timer from the reviewed
    /// values, never from these answers.
    #[sol(rpc)]
    contract GovernanceUpgradeTimerView {
        function INITIAL_DELAY() external view returns (uint256);
        function MAX_ADDITIONAL_DELAY() external view returns (uint256);
        function TIMER_GOVERNANCE() external view returns (address);
        function owner() external view returns (address);
        function deadline() external view returns (uint256);
        function checkDeadline() external view;
    }

    #[sol(rpc)]
    contract ProxyAdminView {
        function owner() external view returns (address);
        function getProxyImplementation(address proxy) external view returns (address);
    }

    /// The CTM's bytecode supplier. `evmPublishingBlock` is the exact read
    /// `L2PlanLib.requirePublished` performs when the CTM leg applies, so a zero here is the
    /// readiness failure that would revert stage 1.
    #[sol(rpc)]
    contract BytecodesSupplierView {
        function evmPublishingBlock(bytes32 bytecodeHash) external view returns (uint256);
    }

    /// Only the hop from the CTM to its ChainAssetHandler, which the pause calls target.
    #[sol(rpc)]
    contract BridgehubView {
        function chainAssetHandler() external view returns (address);
    }

    #[sol(rpc)]
    contract CtmView {
        function protocolVersion() external view returns (uint256);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function currentRelease() external view returns (address);
        function L1_BYTECODES_SUPPLIER() external view returns (address);
        function BRIDGE_HUB() external view returns (address);
    }
}
