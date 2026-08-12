// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemContractRow} from "./ICoreRegistry.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {CTMReleaseFactory} from "./CTMRegistryFactory.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {
    BootstrapAlreadyExecuted,
    EcosystemImplMismatch,
    NotFactoryDeployed,
    RegistryAlreadyInitialized,
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
///         inert. See {protocol-docs/../docs/registry-driven-upgrades.md}.
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
    /// @param releaseFactory The canonical provenance anchor installed on the CTM.
    /// @param releaseFactoryCodehash Inline pin of `releaseFactory`.
    /// @param currentRelease The genesis release pinned as `currentRelease`; must be attested by
    ///        `releaseFactory`, which the CTM re-checks itself.
    /// @param newProtocolVersion The version the CTM moves to.
    /// @param oldProtocolVersionDeadline Until when the departing version stays usable.
    /// @param verifier The verifier pinned for `newProtocolVersion`.
    /// @param verifierCodehash Inline pin of `verifier`.
    /// @param upgradeCut The diamond cut committed for chains upgrading across this edge. It cannot
    ///        be DERIVED the way a transition's is: the departing version predates releases, so
    ///        there is no `fromRelease` to diff against. It is therefore pinned data, committed by
    ///        the manifest hash, with its init target pinned separately below.
    /// @param upgradeCutInitCodehash Inline pin of `upgradeCut.initAddress`.
    /// @param ctmExecutor The `CTMUpgradeExecutor` that receives CTM ownership.
    /// @param ecosystemExecutor The `EcosystemUpgradeExecutor` that receives ProxyAdmin ownership.
    struct BootstrapManifest {
        address ctm;
        uint256 expectedProtocolVersion;
        ProxyAdmin ctmProxyAdmin;
        EcosystemContractRow[] proxyRows;
        address releaseFactory;
        bytes32 releaseFactoryCodehash;
        address currentRelease;
        uint256 newProtocolVersion;
        uint256 oldProtocolVersionDeadline;
        address verifier;
        bytes32 verifierCodehash;
        Diamond.DiamondCutData upgradeCut;
        bytes32 upgradeCutInitCodehash;
        address ctmExecutor;
        address ecosystemExecutor;
    }

    /// @notice Commitment to the pinned manifest — the 32 bytes governance approves.
    bytes32 public manifestHash;

    /// @notice Set once `initialize` has run; the manifest is immutable afterwards.
    bool public initialized;

    /// @notice Set once `migrate` has run. The edge is one-shot: replaying it would re-check a
    ///         starting state that no longer exists anyway, but failing loudly is clearer.
    bool public executed;

    BootstrapManifest internal manifest;

    /// @notice Emitted once the ecosystem has crossed into the registry-driven model.
    event EcosystemBootstrapped(address indexed ctm, address indexed currentRelease, uint256 newProtocolVersion);

    /// @notice One-shot initialization from the audited manifest.
    function initialize(BootstrapManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        if (
            _manifest.ctm == address(0) ||
            address(_manifest.ctmProxyAdmin) == address(0) ||
            _manifest.releaseFactory == address(0) ||
            _manifest.currentRelease == address(0) ||
            _manifest.verifier == address(0) ||
            _manifest.ctmExecutor == address(0) ||
            _manifest.ecosystemExecutor == address(0)
        ) {
            revert ZeroAddress();
        }
        // An edge with no implementation swaps is not a bootstrap; it would silently reduce to
        // "install anchors and hand over authority", which is a different (unreviewed) operation.
        if (_manifest.proxyRows.length == 0) {
            revert RegistryUnknownKey();
        }

        manifest = _manifest;
        manifestHash = keccak256(abi.encode(_manifest));
        initialized = true;
    }

    /// @notice Reverts unless the live ecosystem is exactly the starting state the manifest names.
    /// @dev Runs on the execution path, so a drifted ecosystem cannot be migrated by accident.
    function validate() public view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        BootstrapManifest storage m = manifest;

        // Authority must already rest here, or `migrate` could not perform any of the work.
        if (Ownable2Step(m.ctm).owner() != address(this)) {
            revert NotFactoryDeployed(m.ctm);
        }
        if (m.ctmProxyAdmin.owner() != address(this)) {
            revert NotFactoryDeployed(address(m.ctmProxyAdmin));
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

        m.releaseFactory.requirePin(m.releaseFactoryCodehash);
        m.verifier.requirePin(m.verifierCodehash);
        m.upgradeCut.initAddress.requirePin(m.upgradeCutInitCodehash);

        // The release must be attested by the very factory this migration installs, so the anchor
        // and the release it vouches for cannot be mismatched at the moment of installation.
        ICTMRelease(m.currentRelease).validate();
        if (
            CTMReleaseFactory(m.releaseFactory).deployedFor(ICTMRelease(m.currentRelease).manifestHash()) !=
            m.currentRelease
        ) {
            revert NotFactoryDeployed(m.currentRelease);
        }
    }

    /// @notice Performs the whole edge, then hands authority to the bound executors.
    /// @dev Ordering is load-bearing: the CTM implementation is swapped BEFORE the registry setters
    ///      are called, because those setters only exist on the new implementation.
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
        ctm.setNewVersionUpgrade({
            _cutData: m.upgradeCut,
            _oldProtocolVersion: m.expectedProtocolVersion,
            _oldProtocolVersionDeadline: m.oldProtocolVersionDeadline,
            _newProtocolVersion: m.newProtocolVersion,
            _verifier: m.verifier
        });
        // The anchor first: `setCurrentRelease` checks the release against it.
        ctm.setReleaseFactory(m.releaseFactory);
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
