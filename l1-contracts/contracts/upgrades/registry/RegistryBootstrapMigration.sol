// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemContractRow} from "./ICoreRegistry.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {CTMUpgradeExecutor} from "./CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "./EcosystemUpgradeExecutor.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    EcosystemImplMismatch,
    NotFactoryDeployed,
    RegistryAlreadyInitialized,
    RegistryDuplicateProxyRow,
    RegistryUnknownKey,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../state-transition/L1StateTransitionErrors.sol";

/// @title RegistryBootstrapMigration
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The single, source-checked edge from a pre-registry ecosystem to the registry-driven
///         one: it swaps the pinned implementations, installs the provenance anchor and the genesis
///         release, commits the version edge, and hands CTM + ProxyAdmin authority to the bound
///         executors — after which every later upgrade is a `CTMTransition`, and this object is
///         inert. See the Bootstrap section of {docs/registry-driven-upgrades.md}.
/// @dev Deliberately NOT a general-purpose executor: there is no arbitrary-call surface. The
///      manifest pins every address it touches, and `migrate()` refuses to run unless the live
///      ecosystem is EXACTLY the starting state the manifest names — so the reviewable question is
///      "is this the edge we intend?" rather than "are these calls right against a state I must
///      verify separately".
/// @dev Authority is never parked: `migrate()` acquires nothing it does not hand onward in the same
///      transaction. Governance transfers ownership in, the migration executes, and ownership
///      leaves to the executors before the call returns.
contract RegistryBootstrapMigration {
    using CodehashPinLib for address;

    /// @param ctm The ChainTypeManager proxy this migration bootstraps.
    /// @param expectedProtocolVersion The version the CTM must currently be at (the departing one).
    /// @param ctmProxyAdmin The ProxyAdmin owning every proxy in `proxyRows` (and the CTM proxy).
    /// @param proxyRows Source-checked implementation swaps: each row applies only if the proxy
    ///        currently points at `expectedOldImpl`, and each `implNew` carries an inline pin. The
    ///        CTM's own implementation swap is one of these rows.
    /// @param releaseCodehash The canonical provenance anchor installed on the CTM: the
    ///        `EXTCODEHASH` every release this CTM pins must run.
    /// @param currentRelease The genesis release pinned as `currentRelease`; must be attested by
    ///        `releaseFactory`, which the CTM re-checks itself.
    /// @param newProtocolVersion The version the CTM moves to.
    /// @param oldProtocolVersionDeadline Until when the departing version stays usable.
    /// @param upgradeCut The diamond cut committed for chains upgrading across this edge. It cannot
    ///        be DERIVED the way a transition's is: the departing version predates releases, so
    ///        there is no `fromRelease` to diff against. It is therefore pinned data, committed by
    ///        the manifest hash, with its init target pinned separately below. Its `facetCuts` carry
    ///        no per-facet pins — the one unpinned payload here, and the reason this edge is
    ///        reviewed as legacy calldata rather than as a derived delta.
    /// @param upgradeCutInitCodehash Inline pin of `upgradeCut.initAddress`.
    /// @param ctmExecutor The `CTMUpgradeExecutor` that receives CTM ownership. It must be BOUND to
    ///        `ctm`, otherwise its fixed entrypoints could never drive the CTM it is handed.
    /// @param ctmExecutorCodehash Inline pin of `ctmExecutor`.
    /// @param ecosystemExecutor The `EcosystemUpgradeExecutor` that receives ProxyAdmin ownership.
    ///        It must be BOUND to `ctmProxyAdmin`, for the same reason.
    /// @param ecosystemExecutorCodehash Inline pin of `ecosystemExecutor`.
    struct BootstrapManifest {
        address ctm;
        uint256 expectedProtocolVersion;
        ProxyAdmin ctmProxyAdmin;
        EcosystemContractRow[] proxyRows;
        bytes32 releaseCodehash;
        address currentRelease;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersionDeadline;
        Diamond.DiamondCutData upgradeCut;
        bytes32 upgradeCutInitCodehash;
        address ctmExecutor;
        bytes32 ctmExecutorCodehash;
        address ecosystemExecutor;
        bytes32 ecosystemExecutorCodehash;
    }

    /// @notice Commitment to the pinned manifest — the 32 bytes governance approves.
    bytes32 public manifestHash;

    /// @notice Set once `migrate` has run. The edge is one-shot: replaying it would re-check a
    ///         starting state that no longer exists anyway, but failing loudly is clearer.
    bool public executed;

    BootstrapManifest internal manifest;

    /// @notice Emitted once the ecosystem has crossed into the registry-driven model.
    event EcosystemBootstrapped(address indexed ctm, address indexed currentRelease, uint256 newProtocolVersion);

    /// @notice Pins the audited manifest at construction; the manifest is immutable afterwards.
    constructor(BootstrapManifest memory _manifest) {
        if (
            _manifest.ctm == address(0) ||
            address(_manifest.ctmProxyAdmin) == address(0) ||
            _manifest.currentRelease == address(0) ||
            _manifest.ctmExecutor == address(0) ||
            _manifest.ecosystemExecutor == address(0)
        ) {
            revert ZeroAddress();
        }
        // An edge with no implementation swaps is not a bootstrap; it would silently reduce to
        // "install anchors and hand over authority", which is a different (unreviewed) operation.
        uint256 rowsLength = _manifest.proxyRows.length;
        if (rowsLength == 0) {
            revert RegistryUnknownKey();
        }
        // Same row discipline as {CoreRegistry}: every row is a real, unique edge. Without the
        // per-proxy dedup two rows naming one proxy would BOTH pass the source check (they compare
        // against the same pre-migration implementation) and the last one would silently win — so
        // the edge governance reviewed would not be the edge that executes.
        for (uint256 i = 0; i < rowsLength; ++i) {
            EcosystemContractRow memory row = _manifest.proxyRows[i];
            if (row.proxy == address(0) || row.expectedOldImpl == address(0) || row.implNew == address(0)) {
                revert ZeroAddress();
            }
            for (uint256 j = 0; j < i; ++j) {
                if (_manifest.proxyRows[j].proxy == row.proxy) {
                    revert RegistryDuplicateProxyRow(row.proxy);
                }
            }
        }

        manifest = _manifest;
        manifestHash = keccak256(abi.encode(_manifest));
    }

    /// @notice Reverts unless the live ecosystem is exactly the starting state the manifest names.
    /// @dev Runs on the execution path, so a drifted ecosystem cannot be migrated by accident.
    /// @dev NOT a complete precondition oracle: `setNewVersionUpgrade` additionally requires chain
    ///      migrations to be paused, which is bundle SEQUENCING (stage 0 opens the window) rather
    ///      than ecosystem state this object pins. A migration that passes here can still revert
    ///      inside `migrate` if it is run outside that window.
    function validate() public view {
        BootstrapManifest storage m = manifest;

        // Authority must already rest here, or `migrate` could not perform any of the work.
        address ctmOwner = Ownable2Step(m.ctm).owner();
        if (ctmOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(m.ctm, ctmOwner);
        }
        address proxyAdminOwner = m.ctmProxyAdmin.owner();
        if (proxyAdminOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(address(m.ctmProxyAdmin), proxyAdminOwner);
        }

        // The executors are where ALL of this authority ends up, so they are checked exactly as
        // hard as everything else the manifest names: pinned, and BOUND to the very contracts they
        // receive. An executor bound elsewhere would take ownership its fixed entrypoints cannot
        // drive — and since the edge is one-shot, recovering from that would mean falling back to
        // break-glass, the one authority this design exists to avoid depending on.
        m.ctmExecutor.requirePin(m.ctmExecutorCodehash);
        m.ecosystemExecutor.requirePin(m.ecosystemExecutorCodehash);
        address boundCtm = address(CTMUpgradeExecutor(payable(m.ctmExecutor)).CTM());
        if (boundCtm != m.ctm) {
            revert BootstrapExecutorNotBound(m.ctmExecutor, m.ctm, boundCtm);
        }
        address boundProxyAdmin = address(EcosystemUpgradeExecutor(payable(m.ecosystemExecutor)).PROXY_ADMIN());
        if (boundProxyAdmin != address(m.ctmProxyAdmin)) {
            revert BootstrapExecutorNotBound(m.ecosystemExecutor, address(m.ctmProxyAdmin), boundProxyAdmin);
        }

        // The departing version fixes which ecosystem this edge is valid for.
        uint256 liveVersion = IChainTypeManager(m.ctm).protocolVersion();
        if (liveVersion != m.expectedProtocolVersion) {
            revert OutdatedProtocolVersion(liveVersion, m.expectedProtocolVersion);
        }

        // Every implementation swap is source-checked: replaying a stale migration, or running it
        // against an ecosystem someone already moved, cannot silently re-point a proxy.
        uint256 rowsLength = m.proxyRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            EcosystemContractRow storage row = m.proxyRows[i];
            address liveImpl = m.ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(row.proxy));
            if (liveImpl != row.expectedOldImpl) {
                revert EcosystemImplMismatch(row.proxy, row.expectedOldImpl, liveImpl);
            }
            row.implNew.requirePin(row.implNewCodehash);
        }

        m.upgradeCut.initAddress.requirePin(m.upgradeCutInitCodehash);

        // The release must run the very code this migration installs as the anchor, so the anchor
        // and the release it vouches for cannot be mismatched at the moment of installation.
        ICTMRelease(m.currentRelease).validate();
        if (m.currentRelease.codehash != m.releaseCodehash) {
            revert NotFactoryDeployed(m.currentRelease);
        }
    }

    /// @notice Performs the whole edge, then hands authority to the bound executors.
    /// @dev Ordering is load-bearing: the CTM implementation is swapped BEFORE the registry setters
    ///      are called, because those setters only exist on the new implementation.
    /// @dev Deliberately PERMISSIONLESS. The gate is not the caller but the state: nothing here can
    ///      run until governance has handed this object both ownerships, which IS the approval, and
    ///      every value it then writes is pinned by the manifest. Leaving the trigger open means the
    ///      edge cannot be left half-applied because one privileged account failed to send the final
    ///      transaction.
    function migrate() external {
        if (executed) {
            revert BootstrapAlreadyExecuted();
        }
        // The CTM is `Ownable2Step`: governance's `transferOwnership` only nominated this contract,
        // so claim it here. Doing it inside `migrate` keeps the whole edge — claim, mutate, hand on
        // — in ONE transaction, which is what stops authority resting here between operations.
        if (Ownable2Step(manifest.ctm).pendingOwner() == address(this)) {
            Ownable2Step(manifest.ctm).acceptOwnership();
        }
        validate();
        executed = true;

        BootstrapManifest storage m = manifest;

        uint256 rowsLength = m.proxyRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            m.ctmProxyAdmin.upgrade(ITransparentUpgradeableProxy(m.proxyRows[i].proxy), m.proxyRows[i].implNew);
        }

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        // The cut-taking form, not `setNewVersionUpgradeFromTransition`: there is no transition for
        // this edge to derive from. Chains crossing it therefore use the cut-taking chain-side
        // entrypoint too — `upgradeTransition` stays zero for the departing version, and only
        // registry-driven hops after this one populate it.
        ctm.setNewVersionUpgrade({
            _cutData: m.upgradeCut,
            _oldProtocolVersion: m.expectedProtocolVersion,
            _oldProtocolVersionDeadline: m.oldProtocolVersionDeadline,
            _newProtocolVersion: m.newProtocolVersion
        });
        // The anchor first: `setCurrentRelease` checks the release against it.
        ctm.setReleaseCodehash(m.releaseCodehash);
        ctm.setCurrentRelease(m.currentRelease);

        // Authority leaves in the same transaction it arrived. The ProxyAdmin is plain `Ownable`,
        // so its transfer lands immediately. The CTM is `Ownable2Step`, so this NOMINATES the
        // executor; the handover is completed by `CTMUpgradeExecutor.acceptCTMOwnership()`, which
        // is owner-gated on the executor and therefore the governance bundle's final call. That
        // gate is deliberately not loosened here: an unguarded accept would widen the executor's
        // only ownership-acquiring entrypoint to save one reviewable call.
        Ownable2Step(m.ctm).transferOwnership(m.ctmExecutor);
        m.ctmProxyAdmin.transferOwnership(m.ecosystemExecutor);

        emit EcosystemBootstrapped(m.ctm, m.currentRelease, m.newProtocolVersion);
    }

    /// @notice The pinned starting state and target, for off-chain review tooling.
    function getManifest() external view returns (BootstrapManifest memory) {
        return manifest;
    }
}
