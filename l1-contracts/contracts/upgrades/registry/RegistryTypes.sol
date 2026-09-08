// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Facets} from "../../common/StateTransitionTypes.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";

/// @title Registry data types.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Every struct the registry-driven upgrade objects are built from, in one place: the
///         manifests governance audits, the rows they are made of, and the deploy-time config a
///         bootstrap manifest is assembled from.
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
/// @dev Shared by {ReleaseManifest} and {GenesisConfig} so the deploy-time input and the pinned
///      manifest cannot drift in these fields — the config carries this verbatim into the
///      manifest it builds.
// solhint-disable-next-line gas-struct-packing
struct ReleaseGenesisData {
    bytes fixedForceDeploymentsData;
    bytes32 genesisBatchHash;
    bytes32 genesisBatchCommitment;
    uint64 genesisIndexRepeatedStorageChanges;
}

/// @param l2BytecodeInfos The release's L2 contract set, indexed by {L2EcosystemContract}
///        (length == `L2_ECOSYSTEM_CONTRACT_COUNT` at construction, same slot semantics as the
///        L1 inventories): per member, the VM-specific deployed-bytecode descriptor a force
///        deployment of this release's code at the member's fixed address carries
///        (`UniversalContractUpgradeInfo.deployedBytecodeInfo`); an empty row means the member
///        is not part of this release's force-deployed set. Transitions DERIVE their L2 force
///        deployments from this table ({TransitionDerivationLib.deriveL2Deployments}) — there is
///        no parallel script-side composition to drift from. A release built before an enum
///        append keeps its shorter table, so consumers index by member, never assume the
///        current count.
// solhint-disable-next-line gas-struct-packing
struct ReleaseManifest {
    PinnedContract diamondInit;
    PinnedContract verifier;
    PinnedContract genesisUpgrade;
    GenesisFacet[] genesisFacets;
    ReleaseGenesisData genesis;
    bytes[] l2BytecodeInfos;
}

/// @notice The complete, typed L2 side of one transition AS EXECUTED: the force-deployments,
///         the delegate call the `L2ComplexUpgrader` performs after them, and the factory
///         dependencies the L1 -> L2 transaction carries. This is the FINAL shape a transition
///         serves (`l2Plan()`) and the composer executes — its `deployments` are the
///         table-derived set ({TransitionDerivationLib.deriveL2Deployments}) followed by the
///         authored extras; only {AuthoredL2Plan} is manifest data.
struct L2UpgradePlan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] deployments;
    address delegateTo;
    address delegateComposer;
    uint256[] factoryDepHashes;
}

/// @notice The AUTHORED part of a transition's L2 side — what the manifest pins on top of the
///         table-derived force deployments. Shape-validated (against the combined plan) at
///         transition initialization — a plan that commits data the composed transaction would
///         not execute refuses to exist.
/// @dev This is REVIEWED-AND-PINNED data, not proven state: L1 cannot verify L2 execution
///      effects, so the L1-side convergence guarantee deliberately does not extend here (see
///      the transition contract docs).
/// @param extraDeployments Force deployments the release table cannot express — in practice the
///        version-specific upgrade delegate, force-deployed Unsafe at a bytecode-derived
///        address. Appended AFTER the derived set (order between deployments is free; the
///        delegatecall always runs last).
/// @param delegateComposer The codehash-pinned {IL2DelegateCalldataComposer} that DEFINES what the
///        delegate is called with, from the target release and the ecosystem's Bridgehub — no
///        authored calldata bytes ride the manifest. Zero means the delegate is called with empty
///        calldata; nonzero requires a `delegateTo`.
struct AuthoredL2Plan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] extraDeployments;
    address delegateTo;
    PinnedContract delegateComposer;
    uint256[] factoryDepHashes;
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
/// @param coreRegistry The ecosystem leg of this upgrade: the `CoreRegistry` whose rows the
///        `EcosystemUpgradeExecutor` applies in stage 1 BEFORE the CTM leg, and verifies in
///        stage 2. A zero address means the upgrade has no ecosystem leg. Content provenance is
///        the ecosystem executor's codehash pin; naming it here is what makes participation a
///        reviewed, on-chain-enforced fact rather than a bundle-composition decision.
/// @param upgradeTimer The `GovernanceUpgradeTimer` gating stage 1: stage 0 starts it, stage 1
///        requires its deadline. Bound to the CTM executor (`TIMER_GOVERNANCE`), so nobody else
///        can start it; its `owner` keeps the bounded extension right. Mandatory.
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
    PinnedContract coreRegistry;
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

/// @notice One member of a CTM domain's CURRENT deployment.
/// @dev An all-zero row states the member is ABSENT from this domain, the same way a zero
///      `implNew` states "not upgraded" in an upgrade row. The two row types are deliberately
///      different: this one describes STATE, {ProxyUpgradeRow} describes an OPERATION, and
///      conflating them is what made an inert upgrade row read as "this is what is deployed".
/// @param proxy The proxy address this member is reachable at.
/// @param admin The `ProxyAdmin` administering `proxy`. ZERO means the CTM domain's own admin —
///        the one a bound executor holds; a nonzero admin names a member administered elsewhere
///        (the `ServerNotifier` under its ChainAdmin-owned admin).
/// @param implementation The implementation the proxy currently points at, with its codehash pin,
///        so the inventory is CHECKABLE against live state rather than merely asserted.
struct CTMInventoryRow {
    address proxy;
    ProxyAdmin admin;
    PinnedContract implementation;
}

/// @notice Everything a CTM registry pins, set exactly once at construction: the CTM domain's
///         complete current deployment.
/// @dev Indexed by {CTMContract}, like every other inventory in this model, so slot
///      `uint256(member)` IS that member and a manifest cannot omit one. Members the RELEASE
///      authoritatively describes — the facets, `DiamondInit`, the verifiers, the genesis upgrade
///      — must be EMPTY here: an address described in two objects is two sources that can
///      disagree, and the release is the one chains actually run.
/// @param ctm The CTM whose domain this describes. The pointer lives on that CTM, so the binding
///        is checked rather than assumed.
/// @param members The enum-indexed rows (length `CTM_CONTRACT_COUNT`).
struct CTMRegistryManifest {
    address ctm;
    CTMInventoryRow[] members;
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
/// @param upgradeEngine The pinned bootstrap engine (`BootstrapUpgradeZKsyncOS`), the committed
///        cut's init target. The cut carries NO facet cuts and NO authored calldata: the facet
///        delta cannot be derived at construction (the departing version predates releases, so
///        there is no `fromRelease` to diff against), so the engine removes each chain's live
///        routing and installs the genesis release's facet set AT EXECUTION; and the engine's
///        `ProposedUpgrade` is COMPOSED on read (`upgradeCut()`) from the pinned inputs below by
///        the same composer transitions use — the bootstrap is bootstrap-specific INPUTS, not a
///        second composition path.
/// @param l2Plan The authored L2 remainder, exactly as on a transition: extra deployments, the
///        delegate target and its pinned calldata composer, and the factory dependencies. The
///        table-derived deployments come from `currentRelease`'s own L2 bytecode table.
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
/// @param ecosystemExecutor The `EcosystemUpgradeExecutor` the CTM executor must currently point
///        at. Also storage rather than an immutable (governance may replace it between
///        upgrades), so also outside the codehash pin, and it is the route every later
///        transition's ecosystem leg takes.
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
    address ecosystemExecutor;
    PinnedContract upgradeTimer;
}

/// @notice Everything the deploy flow feeds into a release manifest at build time.
/// @dev A release is version-INDEPENDENT and VM-flag-free: the version schedule is a transition
///      concern, and VM identity is single-sourced from the pinned DiamondInit immutable.
/// @param facets The deployed diamond facet addresses (incl. DiamondInit).
/// @param verifier The verifier a chain at this release runs.
/// @param genesisUpgrade The L1 genesis upgrade contract run at chain creation.
/// @param genesis The genesis payload shared verbatim with {ReleaseManifest} ({ReleaseGenesisData}).
// solhint-disable-next-line gas-struct-packing
struct GenesisConfig {
    Facets facets;
    address verifier;
    address genesisUpgrade;
    ReleaseGenesisData genesis;
    bytes[] l2BytecodeInfos;
}
