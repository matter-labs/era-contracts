// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice Canonical identifier for L1 ecosystem contracts shared by every CTM.
///         Used as the lookup key of `ICoreRegistry` getters; the registry maps each
///         entry to its proxy address (version-independent) and per-version
///         implementation addresses.
/// @dev The enum is APPEND-ONLY: new variants must be added at the end and existing
///      variants must never be reordered or removed, because the numeric values are
///      compiled into registry implementations across protocol versions.
enum EcosystemContract {
    Bridgehub,
    MessageRoot,
    CTMDeploymentTracker,
    ChainAssetHandler,
    ChainRegistrationSender,
    AssetTracker,
    L1AssetRouter,
    L1Nullifier,
    L1NativeTokenVault
}

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         The enum value is VM-neutral; `CoreOnGatewayHelper.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name, and per-CTM
///         registries map it to the pinned L2 bytecode hash per protocol version.
/// @dev APPEND-ONLY (see `EcosystemContract`).
enum CoreContract {
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropHandler,
    L2AssetTracker,
    L2WrappedBaseToken,
    L2MessageVerification,
    L2InteropRootStorage,
    GWAssetTracker,
    BeaconProxy,
    L2V31Upgrade,
    L2SharedBridgeLegacy,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin,
    TransparentUpgradeableProxy
}

/// @notice Canonical identifier for CTM / state-transition contracts.
///         The enum value is VM-neutral; `DeployCTML1OrGateway.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name, and per-CTM
///         registries map it to the deployed address per protocol version.
/// @dev APPEND-ONLY (see `EcosystemContract`).
enum CTMContract {
    // ---- Diamond facets ----
    AdminFacet,
    MailboxFacet,
    ExecutorFacet,
    MigratorFacet,
    CommitterFacet,
    DiamondInit,
    // ---- Infrastructure ----
    ValidatorTimelock,
    ChainTypeManager,
    // ---- Verifiers ----
    VerifierFflonk,
    VerifierPlonk,
    DualVerifier,
    TestnetVerifier,
    // ---- Gateway CTM deployers ----
    GatewayCTMDeployerCTM,
    GatewayCTMDeployerVerifiers,
    // ---- DA ----
    BlobsL1DAValidatorZKsyncOS,
    // ---- Appended variants (the enum is append-only) ----
    GettersFacet,
    DefaultUpgrade,
    L1GenesisUpgrade
}

/// @notice How a built-in contract is deployed in ZKsyncOS upgrades.
/// SystemProxy: deployed via conductContractUpgrade (behind a system proxy).
/// Unsafe: force-deployed directly (no proxy upgrade flow).
enum ZKsyncOSUpgradeType {
    SystemProxy,
    Unsafe
}
