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
    L2V34Upgrade,
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
///         Also the index space of the CTM-domain upgrade inventory: transition and bootstrap
///         manifests carry `ProxyUpgradeRow[CTM_CONTRACT_COUNT]` fixed arrays indexed by this
///         enum (same slot semantics as `L1EcosystemContract`). Only the members that are
///         TUPPs under the CTM-domain `ProxyAdmin` (ChainTypeManager, ValidatorTimelock,
///         BytecodesSupplier, PermissionlessValidator) can meaningfully participate — a row in
///         any other slot can never apply because the bound admin does not administer it. The
///         `ServerNotifier` is deliberately absent from the upgrade flow: it sits under its own
///         chainAdmin-owned `ProxyAdmin` (see `DeployCTM.deployServerNotifier`).
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
    L1GenesisUpgrade,
    BytecodesSupplier,
    PermissionlessValidator
}

/// @notice How a built-in contract is deployed in ZKsyncOS upgrades.
/// SystemProxy: deployed via conductContractUpgrade (behind a system proxy).
/// Unsafe: force-deployed directly (no proxy upgrade flow).
enum ZKsyncOSUpgradeType {
    SystemProxy,
    Unsafe
}

/// @notice Canonical identifier for L1 ecosystem (core) contracts — the shared singletons of
///         the ecosystem domain. ONE enum for both deployment identity and upgrades: member
///         names are the deploy artifact names, and a `CoreRegistryManifest` carries its
///         upgrades as a `ProxyUpgradeRow[L1_ECOSYSTEM_CONTRACT_COUNT]` fixed array indexed by
///         this enum — slot `uint256(member)` IS that contract's row, a zero `implNew` in it is
///         the explicit "not upgraded" statement, and the fixed length makes completeness
///         structural: a manifest cannot omit a slot.
/// @dev APPEND-ONLY: numeric values are stable identifiers — never reorder or remove members.
///      Appending one grows the manifest array, which the next release's objects pick up.
enum L1EcosystemContract {
    L1Bridgehub,
    L1ChainAssetHandler,
    L1MessageRoot,
    L1Nullifier,
    L1AssetRouter,
    L1NativeTokenVault,
    L1InteropHandler,
    CTMDeploymentTracker,
    ChainRegistrationSender
}

/// @dev The inventory lengths, DERIVED from the enums — never hand-counted. Manifest inventory
///      arrays are dynamic (`ProxyUpgradeRow[]`) with their length checked against these at
///      construction: solc cannot fold `type(...).max` in static array-length position, so a
///      fixed-size array type would force these back to literals.
uint256 constant L1_ECOSYSTEM_CONTRACT_COUNT = uint256(type(L1EcosystemContract).max) + 1;
uint256 constant CTM_CONTRACT_COUNT = uint256(type(CTMContract).max) + 1;
