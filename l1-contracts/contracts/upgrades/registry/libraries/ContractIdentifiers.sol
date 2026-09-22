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
    // Atomic-interop built-ins; the bootloader reads the commitment tree's storage.
    L2InteropCommitmentTree,
    AtomicFlowManager,
    // ---- Appended members (the enum is append-only) ----
    // ZKsync OS kernel built-ins with l1-contracts EVM bytecodes (system space, 0x800x). Members
    // here so the release's L2 bytecode table covers the FULL force-deployed set and transitions
    // can derive their L2 deployments from it.
    L2BaseToken,
    L1Messenger,
    SystemContext,
    // The retired v31 GWAssetTracker's system proxy: its table row pins the neutralizing
    // implementation (`EmptyContract`) every release re-asserts at the reserved address.
    RemovedGWAssetTracker,
    // The ComplexUpgrader (0x800f) behind its system proxy; see the ComplexUpgrader transition in
    // {protocol-docs/chain-lifecycle.md}.
    L2ComplexUpgrader
}

/// @notice Canonical identifier for CTM / state-transition contracts.
///         The enum value is VM-neutral; `DeployCTML1OrGateway.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name, and per-CTM
///         registries map it to the deployed address per protocol version.
///         Also the index space of the CTM-domain upgrade inventory: transition and bootstrap
///         manifests carry `ProxyUpgradeRow[CTM_CONTRACT_COUNT]` fixed arrays indexed by this
///         enum (same slot semantics as `L1EcosystemContract`). Only the members that are
///         TUPPs can meaningfully participate: those under the CTM-domain `ProxyAdmin`
///         (ChainTypeManager, ValidatorTimelock, BytecodesSupplier, PermissionlessValidator)
///         through the executor's bound admin, and the `ServerNotifier` through the row's
///         explicitly named admin — its own chainAdmin-owned `ProxyAdmin` (see
///         `DeployCTM.deployServerNotifier`), which the executor applies only if it owns and
///         otherwise leaves to that administrator. A row in a facet or verifier slot can never
///         apply.
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
    PermissionlessValidator,
    ServerNotifier
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
///         names are the deploy artifact names, and a `CoreTransitionManifest` carries its
///         upgrades as a `ProxyUpgradeRow[L1_ECOSYSTEM_CONTRACT_COUNT]` fixed array indexed by
///         this enum — slot `uint256(member)` IS that contract's row, and a zero `implNew` in it
///         is the "not upgraded" statement. The fixed length guarantees every member HAS a slot;
///         it does not guarantee that preparation wrote every intended change into one, since an
///         inert slot and a row that was never built are the same bytes (see
///         {ProxyUpgradeRowLib.toRows}).
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
uint256 constant L2_ECOSYSTEM_CONTRACT_COUNT = uint256(type(L2EcosystemContract).max) + 1;
