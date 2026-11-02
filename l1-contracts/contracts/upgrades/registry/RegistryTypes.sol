// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";

/// @title Registry data types.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Every struct the registry-driven upgrade objects are built from, in one place: the
///         manifests governance audits and the rows they are made of.
/// @dev They live here rather than next to their contracts because they are the reviewable
///      artifact of the whole model — see {protocol-docs/README.md} and {docs/registry-driven-upgrades.md}.

/// @notice One facet installed on every chain created from a CTM release.
/// @dev The facet's selector routing is NOT stored: every facet is self-describing
///      (`ISelfDescribingFacet.selectors()`), and a stored copy would only be a second,
///      unverified source that could disagree with it. Consumers (genesis installation,
///      transition delta derivation) read the routing from the facet itself.
struct GenesisFacet {
    address facet;
    bool isFreezable;
}

/// @notice The chain state a release names that is not a routing row: the force-deployment
///         descriptor and the genesis batch.
// solhint-disable-next-line gas-struct-packing
struct ReleaseGenesisData {
    bytes fixedForceDeploymentsData;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
}

/// @notice Which members differ between a transition's two releases, so a reviewer reads
///         "verifier only" off one call instead of diffing two manifests. Derived on read from
///         the two pinned releases; never stored.
/// @param diamondInit The `DiamondInit` new chains are created with.
/// @param verifier The proof verifier chains route to.
/// @param genesisUpgrade The L1 genesis upgrade contract.
/// @param genesisFacets The facet set (any facet address or freezability).
/// @param l2BytecodeInfos The L2 implementation table (any row).
/// @param l2SystemProxyBytecodeInfo The shared L2 system-proxy shell.
/// @param fixedForceDeploymentsData The fixed force-deployments blob.
/// @param genesisBatch The genesis batch hash or its repeated-storage index.
struct ReleaseDiff {
    bool diamondInit;
    bool verifier;
    bool genesisUpgrade;
    bool genesisFacets;
    bool l2BytecodeInfos;
    bool l2SystemProxyBytecodeInfo;
    bool fixedForceDeploymentsData;
    bool genesisBatch;
}

/// @param protocolVersion The protocol version this release IS, packed SemVer: the version of every
///        chain on it, and the edge every transition into or out of it reads instead of authoring
///        one. One release per version — a bump that changes no member still deploys a release,
///        differing from its predecessor in this field alone.
/// @param l2BytecodeInfos The release's L2 contract set, indexed by {L2EcosystemContract}
///        (length == `L2_ECOSYSTEM_CONTRACT_COUNT` at construction, same slot semantics as the
///        L1 inventories): per member, the ZKsync OS bytecode info of the IMPLEMENTATION this
///        release runs behind the member's system proxy; an empty row means the member is not
///        part of this release's force-deployed set. Transitions DERIVE their L2 force
///        deployments from this table ({TransitionDerivationLib.deriveL2Deployments}) — there is
///        no parallel script-side composition to drift from. A release built before an enum
///        append keeps its shorter table, so consumers index by member, never assume the
///        current count.
/// @param l2SystemProxyBytecodeInfo The ZKsync OS bytecode info of the `SystemContractProxy`
///        shell every table member sits behind — ONE descriptor for the whole set, since the shell
///        is the same contract at every system address. The derivation joins it to each member's
///        implementation row to form the `(implementation, proxy)` descriptor a system-proxy
///        upgrade executes, so the shell is never repeated per row. Empty only when the table is.
// solhint-disable-next-line gas-struct-packing
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

/// @notice The complete, typed L2 side of one transition AS EXECUTED: the force-deployments,
///         the delegate call the `L2ComplexUpgrader` performs after them, and the factory
///         dependencies the L1 -> L2 transaction carries. This is the FINAL shape a transition
///         serves (`l2Plan()`) and the composer executes. It is CONSTRUCTED at initialization
///         ({L2PlanLib.build}) — never authored: `deployments` is the table-derived set
///         ({TransitionDerivationLib.deriveL2Deployments}) followed by one Unsafe deployment per
///         authored bytecode info, `delegateTo` the delegate's bytecode-derived address, and
///         `factoryDepHashes` the observable hash of every bytecode those deployments install.
///         Only {AuthoredL2Plan} is manifest data.
struct L2UpgradePlan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] deployments;
    address delegateTo;
    address delegateComposer;
    uint256[] factoryDepHashes;
}

/// @notice The AUTHORED L2 input of one transition — only what a release table cannot express
///         and the object cannot derive: the bytecodes to force-deploy beside the table-derived
///         set, and the code that defines the delegate's calldata. Everything else of the L2 side
///         (addresses, the delegate target, the factory dependencies) is a function of these and
///         is constructed at initialization, so a manifest cannot commit a plan the composed
///         transaction would not execute.
/// @dev This is REVIEWED data, not proven state: L1 cannot verify L2 execution effects, so the
///      L1-side convergence guarantee deliberately does not extend here (see the transition
///      contract docs). What remains review work is what the delegate DOES — its bytecode hash
///      names an auditable artifact, not a behavior.
/// @param delegateBytecodeInfo The canonical ZKsync OS bytecode info (see {ZKSyncOSBytecodeInfo})
///        of the version-specific upgrade delegate the `L2ComplexUpgrader` delegatecalls after
///        the deployments. Force-deployed Unsafe at the address its own info derives, so it can
///        never land on a fixed built-in or a table-derived target. EMPTY means no delegate — an
///        L1-only edge, legal only when nothing is deployed on L2 either.
/// @param extraBytecodeInfos Further Unsafe force deployments the delegate needs beside the
///        table-derived set, each at its bytecode-derived address. Usually empty.
/// @param delegateComposer The {IL2DelegateCalldataComposer} that DEFINES what the delegate is
///        called with, from the target release and the ecosystem's Bridgehub — no authored
///        calldata bytes ride the manifest. Set exactly when there is a delegate (see
///        {L2PlanLib.build}).
struct AuthoredL2Plan {
    bytes delegateBytecodeInfo;
    bytes[] extraBytecodeInfos;
    address delegateComposer;
}

/// @notice What chains upgrade FROM and TO, and by when — nothing else. The version edge is not a
///         field: it is the two releases' own versions ({ReleaseManifest.protocolVersion}).
///         Infrastructure changes live on {ProxyUpgradeTransitionManifest}; see
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @param upgradeEngine The diamond cut's init delegatecall target implementing
///        `upgradeFromTransition` — the registry-model name for what deploy tooling calls the
///        per-version "default upgrade" contract (`DefaultUpgrade` and its versioned subclasses).
/// @param oldProtocolVersionDeadline When the departing version stops being usable.
/// @param upgradeTimestamp The earliest a chain may execute its own diamond upgrade.
// solhint-disable-next-line gas-struct-packing
struct TransitionManifest {
    address fromRelease;
    address newRelease;
    address upgradeEngine;
    uint256 oldProtocolVersionDeadline;
    uint256 upgradeTimestamp;
    AuthoredL2Plan l2Plan;
}

/// @notice One proxy's upgrade row: a SOURCE-CHECKED edge, not just a target.
/// @param proxy The proxy this row upgrades.
/// @param expectedOldImpl The implementation the proxy must currently point at for this row to
///        apply. This is the replay guard: after a later upgrade moves the proxy on, replaying
///        this row cannot silently downgrade it — the source no longer matches.
/// @param implNew The implementation the proxy points at afterwards. A ZERO address marks an
///        inventory slot as EXPLICITLY not upgraded; such a slot never becomes a row.
/// @param callInitializeUpgrade Whether the swap reinitializes. There is NO calldata and NO
///        data anywhere on the row: `true` executes `upgradeAndCall` with the FIXED,
///        argument-less `IProxyUpgradeInitializable.initializeUpgrade()` selector (`false` is a
///        plain `ProxyAdmin.upgrade`). Whatever the reinitializer needs lives in the audited
///        implementation itself — constants, or immutables on L1 (see {IUpgradeInit.sol}). A
///        manifest can therefore never route the init call to an arbitrary function or smuggle
///        arguments into it.
/// @dev No admin field: a row is always applied through the applying contract's bound
///      `ProxyAdmin`, which administers every proxy of its domain — the `ServerNotifier` included
///      (see {docs/upgrade-operations.md}).
// solhint-disable-next-line gas-struct-packing
struct ProxyUpgradeRow {
    address proxy;
    address expectedOldImpl;
    address implNew;
    bool callInitializeUpgrade;
}

/// @notice The proxy-administration domain a {ProxyUpgradeTransitionManifest} belongs to. It fixes
///         the inventory's index space and length, and which executor may apply it.
/// @dev APPEND-ONLY, like the inventory enums.
enum ProxyUpgradeDomain {
    // The ecosystem's shared singletons under the ecosystem `ProxyAdmin`, indexed by
    // {L1EcosystemContract}; applied by `CoreUpgradeExecutor`.
    Core,
    // One CTM domain's proxies under its own `ProxyAdmin`, indexed by {CTMContract}; applied by that
    // CTM's `CTMUpgradeExecutor`.
    CTM
}

/// @notice Everything a proxy upgrade transition pins, set exactly once at construction.
/// @dev Carries NO protocol version (a version is a CTM release's, {ReleaseManifest.protocolVersion})
///      and NO proxy admin (each domain's executor is bound to its immutable `ProxyAdmin`). See
///      {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @param domain The domain the inventory belongs to. Part of the pinned manifest, so it is covered
///        by `manifestHash` and by the object's construction arguments.
/// @param proxyUpgrades The domain's inventory, indexed by its contract enum ({L1EcosystemContract}
///        or {CTMContract}): slot `uint256(member)` is that contract's row and a zero `implNew` is the
///        "not upgraded" statement. The length MUST be exactly the domain's member count (enforced at
///        construction), so every contract of the domain HAS a slot — which is not the same as every
///        intended change having been written into one (see {ProxyUpgradeRowLib.toRows}). In the CTM
///        domain only the TUPPs under the CTM `ProxyAdmin` can apply; ecosystem singletons are not
///        expressible there.
/// @param upgradeEngine The `IProxyUpgradeEngine` the domain's executor delegatecalls to apply
///        this transition: `DefaultProxyUpgradeEngine` (the rows and nothing else) or a release's
///        subclass of it that adds the upgrade's follow-up calls as audited code. Never zero.
struct ProxyUpgradeTransitionManifest {
    ProxyUpgradeDomain domain;
    ProxyUpgradeRow[] proxyUpgrades;
    address upgradeEngine;
}

/// @notice What a domain executor hands its transition's `upgradeEngine`. Built by the executor
///         from its own immutable bindings, never from the manifest or the caller.
/// @dev The engine runs by delegatecall, so it cannot read these from the executor's immutables
///      (an immutable in the engine is the ENGINE's bytecode) and must not read its own storage
///      (that is the executor's): this struct is its only view of where it runs.
/// @param transition The `ProxyUpgradeTransition` being applied.
/// @param upgradeEngine The engine itself (`address(this)` is the executor while it runs), so a
///        release engine can read its own typed configuration through an external call.
/// @param domain The executor's domain.
/// @param proxyAdmin The executor's bound `ProxyAdmin`, owned by the executor.
/// @param chainTypeManager The CTM executor's bound ChainTypeManager; zero in the `Core` domain.
// solhint-disable-next-line gas-struct-packing
struct ProxyUpgradeContext {
    address transition;
    address upgradeEngine;
    ProxyUpgradeDomain domain;
    address proxyAdmin;
    address chainTypeManager;
}
