// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
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
///         base system contract hashes, the force-deployment descriptor and the genesis batch.
/// @dev Shared by {ReleaseManifest} and {GenesisConfig} so the deploy-time input and the pinned
///      manifest cannot drift in these fields — the config carries this verbatim into the
///      manifest it builds.
// solhint-disable-next-line gas-struct-packing
struct ReleaseGenesisData {
    bytes32 bootloaderHash;
    bytes32 defaultAccountHash;
    bytes32 evmEmulatorHash;
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
    bytes delegateCalldata;
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
struct AuthoredL2Plan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] extraDeployments;
    address delegateTo;
    bytes delegateCalldata;
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
// solhint-disable-next-line gas-struct-packing
struct ProxyUpgradeRow {
    address proxy;
    address expectedOldImpl;
    PinnedContract implNew;
    bool callInitializeUpgrade;
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
///        CTM's own implementation swap is one of these slots.
/// @param currentRelease The pinned genesis release installed as `currentRelease`. Its
///        `codehash` doubles as the CTM's canonical provenance anchor (`releaseCodehash`):
///        every release this CTM ever pins must run exactly that code.
/// @param newProtocolVersion The version the CTM moves to.
/// @param oldProtocolVersionDeadline Until when the departing version stays usable.
/// @param upgradeCut The diamond cut committed for chains upgrading across this edge. The facet
///        delta cannot be derived at CONSTRUCTION the way a transition's is — the departing
///        version predates releases, so there is no `fromRelease` to diff against — so the cut
///        carries NO facet cuts at all: its init target (pinned below) is the bootstrap engine,
///        which derives the removals from each chain's own live diamond storage and the installs
///        from its immutable-pinned genesis release AT EXECUTION. What remains reviewed as
///        pinned calldata is the engine init payload (the `ProposedUpgrade`).
/// @param upgradeCutInitCodehash Inline pin of `upgradeCut.initAddress`.
/// @param ctmExecutor The pinned `CTMUpgradeExecutor` that receives BOTH CTM ownership and the
///        CTM-domain `ProxyAdmin` — the whole CTM domain lands under one executor. It must be
///        BOUND to `ctm` AND to `ctmProxyAdmin`, otherwise its fixed entrypoints could never
///        drive what it is handed.
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
    Diamond.DiamondCutData upgradeCut;
    bytes32 upgradeCutInitCodehash;
    PinnedContract ctmExecutor;
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
