// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";

/// @title Registry data types.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Every struct the registry-driven upgrade objects are built from, in one place: the
///         manifests governance audits and the rows they are made of.
/// @dev They live here rather than next to their contracts because they are the reviewable
///      artifact of the whole model — see {protocol-docs/README.md} and {docs/registry-driven-upgrades.md}.

/// @notice An address together with the MANDATORY `EXTCODEHASH` pin of the code it must run —
///         the unit every manifest names contracts in. Pins sit beside the address they protect
///         (there is no detached, optional pin list) and are held against live code by
///         `validate()` / `verifyAll()`.
struct PinnedContract {
    address addr;
    bytes32 codehash;
}

/// @notice One facet installed on every chain created from a CTM release.
/// @dev The facet's selector routing is NOT stored: every facet is self-describing
///      (`ISelfDescribingFacet.selectors()`), and the `codehash` pin freezes that
///      self-description together with the code — a stored copy would only be a second,
///      unverified source that could disagree with it. Consumers (genesis installation,
///      transition delta derivation) read the routing from the pinned facet.
struct GenesisFacet {
    PinnedContract facet;
    bool isFreezable;
}

/// @notice The chain state a release pins that is neither a routing row nor a codehash pin: the
///         force-deployment descriptor and the genesis batch.
// solhint-disable-next-line gas-struct-packing
struct ReleaseGenesisData {
    bytes fixedForceDeploymentsData;
    bytes32 genesisBatchHash;
    bytes32 genesisBatchCommitment;
    uint64 genesisIndexRepeatedStorageChanges;
}

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
    PinnedContract diamondInit;
    PinnedContract verifier;
    PinnedContract genesisUpgrade;
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
/// @dev This is REVIEWED-AND-PINNED data, not proven state: L1 cannot verify L2 execution
///      effects, so the L1-side convergence guarantee deliberately does not extend here (see
///      the transition contract docs). What remains review work is what the delegate DOES — its
///      bytecode hash names an auditable artifact, not a behavior.
/// @param delegateBytecodeInfo The canonical ZKsync OS bytecode info (see {ZKSyncOSBytecodeInfo})
///        of the version-specific upgrade delegate the `L2ComplexUpgrader` delegatecalls after
///        the deployments. Force-deployed Unsafe at the address its own info derives, so it can
///        never land on a fixed built-in or a table-derived target. EMPTY means no delegate — an
///        L1-only edge, legal only when nothing is deployed on L2 either.
/// @param extraBytecodeInfos Further Unsafe force deployments the delegate needs beside the
///        table-derived set, each at its bytecode-derived address. Usually empty.
/// @param delegateComposer The codehash-pinned {IL2DelegateCalldataComposer} that DEFINES what the
///        delegate is called with, from the target release and the ecosystem's Bridgehub — no
///        authored calldata bytes ride the manifest. Zero means the delegate is called with empty
///        calldata; nonzero requires a delegate.
struct AuthoredL2Plan {
    bytes delegateBytecodeInfo;
    bytes[] extraBytecodeInfos;
    PinnedContract delegateComposer;
}

/// @param upgradeEngine The diamond cut's init delegatecall target implementing
///        `upgradeFromTransition` — the registry-model name for what deploy tooling calls the
///        per-version "default upgrade" contract (`DefaultUpgrade` and its versioned subclasses).
/// @param proxyUpgrades The CTM-DOMAIN inventory, indexed by {CTMContract} (same slot semantics
///        and construction-time length check — `CTM_CONTRACT_COUNT` — as
///        {CoreRegistryManifest}): implementation swaps for the CTM proxy itself and the
///        per-CTM proxies under its own ProxyAdmin. Applied by the CTM-bound executor BEFORE
///        the version commit, so a transition whose commit needs the new CTM implementation
///        carries that swap itself. Ecosystem singletons (bridges, Bridgehub, MessageRoot) are
///        NOT expressible here — a CTM is one of possibly many and upgrades on its own cadence;
///        shared contracts belong to the core registry. All slots zero when the CTM domain's
///        implementations do not change.
/// @param upgradeTimer The `GovernanceUpgradeTimer` gating stage 1: stage 0 starts it, stage 1
///        requires its deadline. Bound to the coordinating `EcosystemUpgradeExecutor`
///        (`TIMER_GOVERNANCE`), so nobody else can start it; its `owner` keeps the bounded
///        extension right. Mandatory.
// solhint-disable-next-line gas-struct-packing
struct TransitionManifest {
    uint256 oldProtocolVersion;
    uint256 newProtocolVersion;
    address fromRelease;
    address newRelease;
    PinnedContract upgradeEngine;
    ProxyUpgradeRow[] proxyUpgrades;
    uint256 oldProtocolVersionDeadline;
    uint256 upgradeTimestamp;
    AuthoredL2Plan l2Plan;
    PinnedContract upgradeTimer;
}

/// @notice One proxy's upgrade row: a SOURCE-CHECKED edge, not just a target.
/// @param proxy The proxy this row upgrades.
/// @param expectedOldImpl The implementation the proxy must currently point at for this row to
///        apply. This is the replay guard: after a later upgrade moves the proxy on, replaying
///        this row cannot silently downgrade it — the source no longer matches.
/// @param implNew The pinned implementation the proxy points at afterwards. A ZERO address marks
///        an inventory slot as EXPLICITLY not upgraded; such a slot never becomes a row.
/// @param callInitializeUpgrade Whether the swap reinitializes. There is NO calldata and NO
///        data anywhere on the row: `true` executes `upgradeAndCall` with the FIXED,
///        argument-less `IProxyUpgradeInitializable.initializeUpgrade()` selector (`false` is a
///        plain `ProxyAdmin.upgrade`). Whatever the reinitializer needs lives in the audited
///        implementation itself — constants, or immutables on L1, both pinned by the row's
///        codehash (see {IUpgradeInit.sol}). A manifest can therefore never route the init call
///        to an arbitrary function or smuggle arguments into it.
/// @param admin The `ProxyAdmin` administering `proxy`. ZERO means the applying executor's own
///        bound admin — the common case. A nonzero admin names a proxy administered elsewhere (the
///        `ServerNotifier` under its chainAdmin-owned admin): reads go through it, because a
///        transparent proxy answers `implementation()` only to its own admin, and the row applies
///        only if the applying contract OWNS it — otherwise stage 1 leaves the row to that
///        administrator (event-logged) and stage 2 still requires it applied. The row therefore
///        names the action in the reviewed description whoever ends up executing it.
// solhint-disable-next-line gas-struct-packing
struct ProxyUpgradeRow {
    address proxy;
    address expectedOldImpl;
    PinnedContract implNew;
    bool callInitializeUpgrade;
    ProxyAdmin admin;
}

/// @notice One CTM leg of an ecosystem upgrade operation: a transition and the CTM-bound
///         executor that applies it. The pair is what binds a transition to a CTM.
struct CTMLeg {
    address executor;
    address transition;
}

/// @notice Everything an `EcosystemUpgradeOperation` pins, set exactly once at construction —
///         the unit the lifecycle coordinator drives through its three stages. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @param coreRegistry The ecosystem leg — the `CoreRegistry` the `CoreUpgradeExecutor` applies
///        in stage 1 BEFORE every CTM leg and verifies in stage 2 — or zero when the operation has
///        none. Named here and only here: transitions describe their CTM's change, the operation
///        commits the association with the ecosystem change.
/// @param legs The CTM legs, applied in this order in stage 1. At least one; no two legs may
///        share a CTM.
struct OperationManifest {
    address coreRegistry;
    CTMLeg[] legs;
}

/// @notice Everything a core registry instance pins, set exactly once at construction.
/// @dev Carries NO protocol version (version-schedule identity is owned by {CTMTransition})
///      and NO proxy admin (the `EcosystemUpgradeExecutor` is bound to its immutable
///      `ProxyAdmin`). A core registry pins ONLY the ecosystem inventory.
/// @param proxyUpgrades The COMPLETE ecosystem inventory, indexed by {L1EcosystemContract}:
///        slot `uint256(member)` is that contract's row and a zero `implNew` is the explicit
///        "not upgraded" statement. The length MUST be exactly `L1_ECOSYSTEM_CONTRACT_COUNT`
///        (enforced at construction), so a manifest cannot omit a slot.
struct CoreRegistryManifest {
    ProxyUpgradeRow[] proxyUpgrades;
}

/// @param ctm The ChainTypeManager proxy this migration bootstraps.
/// @param expectedProtocolVersion The version the CTM must currently be at (the departing one).
/// @param ctmProxyAdmin The ProxyAdmin owning every proxy in `proxyUpgrades` (and the CTM proxy).
/// @param proxyUpgrades The CTM-domain inventory, indexed by {CTMContract} (same slot semantics
///        as {CoreRegistryManifest}): each participating slot applies only if the proxy
///        currently points at `expectedOldImpl`, and each `implNew` carries an inline pin. The
///        CTM's own implementation swap is one of these slots. A row under a FOREIGN admin (the
///        ServerNotifier's) is left to that administrator: `migrate()` hands onward only
///        `ctmProxyAdmin`, so a foreign admin must never be transferred to this one-shot object —
///        hand it to the executor, or keep it and apply the row yourself before stage 2.
/// @param currentRelease The pinned genesis release installed as `currentRelease`. Its
///        `codehash` doubles as the CTM's canonical provenance anchor (`releaseCodehash`):
///        every release this CTM ever pins must run exactly that code.
/// @param newProtocolVersion The version the CTM moves to.
/// @param oldProtocolVersionDeadline Until when the departing version stays usable.
/// @param upgradeEngine The pinned bootstrap engine (`BootstrapUpgrade`), the committed
///        cut's init target. The cut carries NO facet cuts and NO authored calldata: the facet
///        delta cannot be derived at construction (the departing version predates releases, so
///        there is no `fromRelease` to diff against), so the engine removes each chain's live
///        routing and installs the genesis release's facet set AT EXECUTION. The engine is
///        version-independent and holds nothing of its own: `currentRelease`, the version edge,
///        the schedule and the L2 plan below are all read from this object at execution
///        (`upgradeFromBootstrap`), composing the L2 transaction with the same composer
///        transitions use — the bootstrap is bootstrap-specific INPUTS, not a second composition
///        path.
/// @param l2Plan The authored L2 input, exactly as on a transition ({AuthoredL2Plan}); the final
///        plan is constructed from it and `currentRelease`'s own L2 bytecode table.
/// @param upgradeTimestamp The chain-side earliest execution time the composed proposal carries.
/// @param ctmExecutor The pinned `CTMUpgradeExecutor` that receives BOTH CTM ownership and the
///        CTM-domain `ProxyAdmin` — the whole CTM domain lands under one executor. It must be
///        BOUND to `ctm` AND to `ctmProxyAdmin`, otherwise its fixed entrypoints could never
///        drive what it is handed.
/// @param ctmExecutorOwner The governance the executor must ALREADY answer to. Its codehash pin
///        covers the executor's code and immutables but NOT its storage, and ownership is
///        storage: an executor whose ownership moved between deployment and `migrate()` would
///        receive the whole CTM domain on behalf of whoever owns it now. The edge therefore
///        names the expected owner and refuses to hand anything over otherwise — and refuses a
///        PENDING transfer too, which would let a third party claim the domain right after.
/// @param coordinator The `EcosystemUpgradeExecutor` the CTM executor must currently answer to
///        (`coordinator()`). Also storage rather than an immutable (governance may replace it
///        between operations), so also outside the codehash pin — and it is the only address
///        that can drive the executor's lifecycle callbacks afterwards.
/// @param upgradeTimer The pinned `GovernanceUpgradeTimer` whose `checkDeadline()` gates the
///        edge: stage 0 starts the timer, and `migrate()` refuses to run until the operational
///        window has passed — the stage sequencing is enforced by the object itself, not by the
///        order of calls in a reviewed bundle.
struct BootstrapManifest {
    address ctm;
    uint256 expectedProtocolVersion;
    ProxyAdmin ctmProxyAdmin;
    ProxyUpgradeRow[] proxyUpgrades;
    PinnedContract currentRelease;
    uint256 newProtocolVersion;
    uint256 oldProtocolVersionDeadline;
    PinnedContract upgradeEngine;
    AuthoredL2Plan l2Plan;
    uint256 upgradeTimestamp;
    PinnedContract ctmExecutor;
    address ctmExecutorOwner;
    address coordinator;
    PinnedContract upgradeTimer;
}
