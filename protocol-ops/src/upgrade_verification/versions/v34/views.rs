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
    /// The bootstrap manifest, as pinned in `RegistryBootstrapMigration`'s constructor.
    /// Field order and types mirror `RegistryTypes.sol` exactly — the decode is positional.
    #[derive(Debug)]
    struct PinnedContract {
        address addr;
        bytes32 codehash;
    }

    #[derive(Debug)]
    struct ProxyUpgradeRow {
        address proxy;
        address expectedOldImpl;
        PinnedContract implNew;
        bool callInitializeUpgrade;
        address admin;
    }

    #[derive(Debug)]
    struct UniversalContractUpgradeInfo {
        uint8 upgradeType;
        bytes deployedBytecodeInfo;
        address newAddress;
    }

    #[derive(Debug)]
    struct AuthoredL2Plan {
        UniversalContractUpgradeInfo[] extraDeployments;
        address delegateTo;
        PinnedContract delegateComposer;
        uint256[] factoryDepHashes;
    }

    /// Positional mirror of `RegistryTypes.BootstrapManifest`. Every field a reviewer must
    /// agree to is here, so the verifier reads the pinned manifest itself rather than the
    /// prepare's summary of it.
    #[derive(Debug)]
    struct BootstrapManifest {
        address ctm;
        uint256 expectedProtocolVersion;
        address ctmProxyAdmin;
        ProxyUpgradeRow[] proxyUpgrades;
        PinnedContract currentRelease;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersionDeadline;
        PinnedContract upgradeEngine;
        AuthoredL2Plan l2Plan;
        uint256 upgradeTimestamp;
        PinnedContract ctmExecutor;
        address ctmExecutorOwner;
        address ecosystemExecutor;
        PinnedContract upgradeTimer;
    }

    #[sol(rpc)]
    contract RegistryBootstrapMigrationView {
        function executed() external view returns (bool);
        function manifestHash() external view returns (bytes32);
        function getManifest() external view returns (BootstrapManifest memory);
        function validate() external view;
    }

    #[sol(rpc)]
    contract CTMUpgradeExecutorView {
        function CHAIN_TYPE_MANAGER() external view returns (address);
        function CTM_PROXY_ADMIN() external view returns (address);
        function TRANSITION_CODEHASH() external view returns (bytes32);
        function ECOSYSTEM_EXECUTOR() external view returns (address);
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function pendingTransition() external view returns (address);
        function pendingStage() external view returns (uint8);
    }

    #[sol(rpc)]
    contract EcosystemUpgradeExecutorView {
        function PROXY_ADMIN() external view returns (address);
        function CORE_REGISTRY_CODEHASH() external view returns (bytes32);
        function isAuthorizedCTMExecutor(address ctmExecutor) external view returns (bool);
        function owner() external view returns (address);
    }

    #[sol(rpc)]
    contract CoreRegistryView {
        function manifestHash() external view returns (bytes32);
        function ecosystemRows() external view returns (ProxyUpgradeRow[] memory);
        function verifyAll() external view returns (bool);
        function validate() external view;
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
