// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         The enum value is VM-neutral; `CoreOnGatewayHelper.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name, and per-CTM
///         registries map it to the pinned L2 bytecode hash per protocol version.
/// @dev APPEND-ONLY (see `L1EcosystemContract`).
enum L2EcosystemContract {
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropAttributeParser,
    L2InteropHandler,
    L2AssetTracker,
    L2WrappedBaseToken,
    L2MessageVerification,
    L2InteropRootStorage,
    BeaconProxy,
    L2V32Upgrade,
    L2SharedBridgeLegacy,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin,
    TransparentUpgradeableProxy,
    // Atomic-interop built-ins, part of `getZKsyncOSOnlyContracts`: the commitment tree's storage is read
    // by the ZKsync OS bootloader, and Era chains have no atomic interop.
    L2InteropCommitmentTree,
    AtomicFlowManager
}

/// @notice Canonical identifier for CTM / state-transition contracts.
///         The enum value is VM-neutral; `DeployCTML1OrGateway.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name, and per-CTM
///         registries map it to the deployed address per protocol version.
/// @dev APPEND-ONLY (see `L1EcosystemContract`).
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
