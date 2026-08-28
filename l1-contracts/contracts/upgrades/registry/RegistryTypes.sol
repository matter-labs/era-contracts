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
///      artifact of the whole model — see {protocol-docs} and {docs/registry-driven-upgrades.md}.

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

// solhint-disable-next-line gas-struct-packing
struct ReleaseManifest {
    PinnedContract diamondInit;
    PinnedContract verifier;
    PinnedContract genesisUpgrade;
    GenesisFacet[] genesisFacets;
    ReleaseGenesisData genesis;
}

/// @notice The complete, typed L2 side of one transition: the force-deployments, the delegate
///         call the `L2ComplexUpgrader` performs after them, and the factory dependencies the
///         L1 -> L2 transaction carries. Shape-validated at transition initialization — a plan
///         that commits data the composed transaction would not execute refuses to exist.
/// @dev This is REVIEWED-AND-PINNED data, not proven state: L1 cannot verify L2 execution
///      effects, so the L1-side convergence guarantee deliberately does not extend here (see
///      the transition contract docs).
struct L2UpgradePlan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] deployments;
    address delegateTo;
    bytes delegateCalldata;
    uint256[] factoryDepHashes;
}

/// @param upgradeEngine The diamond cut's init delegatecall target implementing
///        `upgradeFromTransition` — the registry-model name for what deploy tooling calls the
///        per-version "default upgrade" contract (`DefaultUpgrade` and its versioned subclasses).
/// @param ctmProxyRows Source-checked implementation swaps in the CTM DOMAIN — the CTM proxy
///        itself and the per-CTM proxies under its own ProxyAdmin (validator timelock, server
///        notifier). Applied by the CTM-bound executor BEFORE the version commit, so a
///        transition whose commit needs the new CTM implementation carries that swap itself.
///        Ecosystem singletons (bridges, Bridgehub, MessageRoot) are NOT expressible here — a
///        CTM is one of possibly many and upgrades on its own cadence; shared contracts belong
///        to the core registry. Empty when the CTM domain's implementations do not change.
// solhint-disable-next-line gas-struct-packing
struct TransitionManifest {
    uint256 oldProtocolVersion;
    uint256 newProtocolVersion;
    address fromRelease;
    address newRelease;
    PinnedContract upgradeEngine;
    ProxyUpgradeRow[] ctmProxyRows;
    uint256 oldProtocolVersionDeadline;
    uint256 upgradeTimestamp;
    L2UpgradePlan l2Plan;
}

/// @notice One ecosystem contract's upgrade row: a SOURCE-CHECKED edge, not just a target.
/// @dev Scope: implementation swaps only — every row executes as a plain `ProxyAdmin.upgrade`.
///      A proxy needing an initializer call as part of its upgrade is deliberately NOT expressible
///      here; expressing it would mean pinning arbitrary calldata, which is a different (and much
///      wider) review surface than "this proxy moves from this implementation to that one". Such
///      an upgrade belongs in a version-specific script until a pinned-initializer row shape is
///      designed and audited on its own terms.
/// @param proxy The ecosystem proxy this row upgrades.
/// @param expectedOldImpl The implementation the proxy must currently point at for this row to
///        apply. This is the replay guard: after a later registry moves the proxy on, replaying
///        this registry cannot silently downgrade it — the source no longer matches.
/// @param implNew The pinned implementation the proxy points at afterwards.
struct ProxyUpgradeRow {
    address proxy;
    address expectedOldImpl;
    PinnedContract implNew;
}

/// @notice Everything a core registry instance pins, set exactly once by {initialize}.
/// @dev Carries NO protocol version (version-schedule identity is owned by {CTMTransition})
///      and NO proxy admin (the `EcosystemUpgradeExecutor` is bound to its immutable
///      `ProxyAdmin`). A core registry pins ONLY the ecosystem contract rows.
struct CoreRegistryManifest {
    ProxyUpgradeRow[] contractRows;
}

/// @param ctm The ChainTypeManager proxy this migration bootstraps.
/// @param expectedProtocolVersion The version the CTM must currently be at (the departing one).
/// @param ctmProxyAdmin The ProxyAdmin owning every proxy in `proxyRows` (and the CTM proxy).
/// @param proxyRows Source-checked implementation swaps: each row applies only if the proxy
///        currently points at `expectedOldImpl`, and each `implNew` carries an inline pin. The
///        CTM's own implementation swap is one of these rows.
/// @param currentRelease The pinned genesis release installed as `currentRelease`. Its
///        `codehash` doubles as the CTM's canonical provenance anchor (`releaseCodehash`):
///        every release this CTM ever pins must run exactly that code.
/// @param newProtocolVersion The version the CTM moves to.
/// @param oldProtocolVersionDeadline Until when the departing version stays usable.
/// @param upgradeCut The diamond cut committed for chains upgrading across this edge. It cannot
///        be DERIVED the way a transition's is: the departing version predates releases, so
///        there is no `fromRelease` to diff against. It is therefore pinned data, committed by
///        the manifest hash, with its init target pinned separately below. Its `facetCuts` carry
///        no per-facet pins — the one unpinned payload here, and the reason this edge is
///        reviewed as legacy calldata rather than as a derived delta.
/// @param upgradeCutInitCodehash Inline pin of `upgradeCut.initAddress`.
/// @param ctmExecutor The pinned `CTMUpgradeExecutor` that receives BOTH CTM ownership and the
///        CTM-domain `ProxyAdmin` — the whole CTM domain lands under one executor. It must be
///        BOUND to `ctm` AND to `ctmProxyAdmin`, otherwise its fixed entrypoints could never
///        drive what it is handed.
struct BootstrapManifest {
    address ctm;
    uint256 expectedProtocolVersion;
    ProxyAdmin ctmProxyAdmin;
    ProxyUpgradeRow[] proxyRows;
    PinnedContract currentRelease;
    uint256 newProtocolVersion;
    uint256 oldProtocolVersionDeadline;
    Diamond.DiamondCutData upgradeCut;
    bytes32 upgradeCutInitCodehash;
    PinnedContract ctmExecutor;
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
}
