// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ManifestStorage} from "../objects/ManifestStorage.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "../libraries/ContractIdentifiers.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {RegistryAuthorityLib} from "../libraries/RegistryAuthorityLib.sol";
import {CTMUpgradeExecutor} from "../executors/CTMUpgradeExecutor.sol";
import {ICommittedUpgrade} from "../objects/ICommittedUpgrade.sol";
import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {VersionEdgeLib} from "../libraries/VersionEdgeLib.sol";
import {IRegistryBootstrapMigration} from "./IRegistryBootstrapMigration.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapNotYetExecuted,
    BootstrapReleaseNotInstalled,
    BootstrapServerNotifierRowMissing,
    ProxyUpgradeRowMismatch,
    RegistryUnknownKey,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {BootstrapManifest, L2UpgradePlan, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {CTMUpgradeComposer} from "../libraries/CTMUpgradeComposer.sol";
import {TransitionDerivationLib} from "../libraries/TransitionDerivationLib.sol";

/// @title RegistryBootstrapMigration
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The single, source-checked edge from a pre-registry ecosystem to the registry-driven
///         one: it swaps the named implementations, installs the genesis release, commits the
///         version edge, and hands CTM + ProxyAdmin authority to the bound executors — after
///         which every later upgrade is a `CTMTransition`, and this object is inert. See the
///         Bootstrap section of {docs/registry-driven-upgrades.md}.
/// @dev Deliberately NOT a general-purpose executor: there is no arbitrary-call surface. The
///      manifest names every address it touches, and `migrate()` refuses to run unless the live
///      ecosystem is EXACTLY the starting state the manifest names — so the reviewable question is
///      "is this the edge we intend?" rather than "are these calls right against a state I must
///      verify separately".
/// @dev Authority is never parked: `migrate()` acquires nothing it does not hand onward in the same
///      transaction. Governance transfers ownership in, the migration executes, and ownership
///      leaves to the executors before the call returns.
contract RegistryBootstrapMigration is IRegistryBootstrapMigration, ManifestStorage {
    /// @notice Set once `migrate` has run. The edge is one-shot: replaying it would re-check a
    ///         starting state that no longer exists anyway, but failing loudly is clearer.
    bool public executed;

    /// @dev The FINAL L2 plan, constructed at construction and stored as its ABI encoding (see
    ///      {CTMTransition} for why).
    bytes internal encodedL2Plan;

    /// @dev The genesis release's version, read at construction (see {newProtocolVersion}).
    uint256 internal derivedNewProtocolVersion;

    /// @notice Stores the audited manifest at construction; it is immutable afterwards.
    constructor(BootstrapManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {
        if (
            _manifest.ctm == address(0) ||
            address(_manifest.ctmProxyAdmin) == address(0) ||
            _manifest.currentRelease == address(0) ||
            _manifest.ctmExecutor == address(0) ||
            _manifest.coreExecutor == address(0) ||
            _manifest.governance == address(0) ||
            _manifest.coordinator == address(0) ||
            _manifest.upgradeEngine == address(0)
        ) {
            revert ZeroAddress();
        }
        // An edge with no implementation swaps is not a bootstrap; it would silently reduce to
        // "install a release and hand over authority", which is a different (unreviewed) operation.
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(_manifest.ctmProxyUpgrades, CTM_CONTRACT_COUNT);
        if (rows.length == 0) {
            revert RegistryUnknownKey();
        }
        // Same row discipline as {CoreTransition} and {EcosystemUpgradeOperation} (shared lib).
        ProxyUpgradeRowLib.validateRows(rows);
        // The notifier's slot is mandatory: its proxy is what `validate()` holds the one-time
        // notifier handover against.
        if (_manifest.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].implNew == address(0)) {
            revert BootstrapServerNotifierRowMissing();
        }
        // The L2 leg, exactly as a transition constructs it: the genesis release's table (the target
        // state, installed in full — there is no departing release to diff against) plus the
        // authored delegate and extras, with the same shape rules ({L2PlanLib.build}).
        ICTMRelease release = ICTMRelease(_manifest.currentRelease);
        uint256 newVersion = release.protocolVersion();
        derivedNewProtocolVersion = newVersion;
        L2UpgradePlan memory plan = L2PlanLib.build(
            TransitionDerivationLib.deriveL2DeploymentsFromTable(
                release.l2BytecodeInfos(),
                release.l2SystemProxyBytecodeInfo()
            ),
            _manifest.l2Plan
        );
        // Held to the edge rules of a `CTMTransition`: chains cross this edge through the same
        // per-chain version checks, so an edge they would refuse must not be committable.
        VersionEdgeLib.requireValidEdge({
            _oldVersion: _manifest.expectedProtocolVersion,
            _newVersion: newVersion,
            _oldVersionDeadline: _manifest.oldProtocolVersionDeadline,
            _upgradeTimestamp: _manifest.upgradeTimestamp,
            _hasL2Side: plan.deployments.length != 0
        });
        encodedL2Plan = abi.encode(plan);
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function getManifest() public view returns (BootstrapManifest memory) {
        return abi.decode(encodedManifest, (BootstrapManifest));
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function newProtocolVersion() external view returns (uint256) {
        return derivedNewProtocolVersion;
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev The genesis release is the edge's target: a chain crossing this edge after the CTM has
    ///      moved on still installs the release ITS OWN committed migration names.
    function upgradeTarget() external view returns (uint256, uint256, address) {
        BootstrapManifest memory m = getManifest();
        return (derivedNewProtocolVersion, m.upgradeTimestamp, m.currentRelease);
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev The stored derived-plus-extra deployments with the authored delegate leg and factory
    ///      dependencies.
    function l2Plan() public view returns (L2UpgradePlan memory) {
        return abi.decode(encodedL2Plan, (L2UpgradePlan));
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function l2UpgradeTx(uint256 _chainId) public view returns (L2CanonicalTransaction memory) {
        BootstrapManifest memory m = getManifest();
        return
            CTMUpgradeComposer.buildL2UpgradeTxFromPlan({
                _plan: l2Plan(),
                _newRelease: ICTMRelease(m.currentRelease),
                _newProtocolVersion: derivedNewProtocolVersion,
                _bridgehub: IChainTypeManager(m.ctm).BRIDGE_HUB(),
                _chainId: _chainId
            });
    }

    /// @inheritdoc IRegistryBootstrapMigration
    /// @dev The engine reads the version edge, schedule and L2 plan from this object at execution,
    ///      so the cut carries nothing but the reference back to it.
    function upgradeCut() public view returns (Diamond.DiamondCutData memory) {
        return CTMUpgradeComposer.buildBootstrapUpgradeCutData(this);
    }

    /// @notice Reverts unless the live ecosystem is exactly the starting state the manifest names
    ///         AND the edge is executable now: both domains' executors are governed and bound as the
    ///         manifest names (the ecosystem `ProxyAdmin` already handed to the core executor earlier
    ///         in the same governance bundle), and the one-time ServerNotifier handover to the CTM
    ///         domain has completed.
    /// @dev Runs on the execution path, so a drifted ecosystem cannot be migrated by accident and
    ///      the preconditions are enforced by the object itself, not by call order in a bundle.
    function validate() public view {
        BootstrapManifest memory m = getManifest();

        // Authority must already rest here, or `migrate` could not perform any of the work.
        address ctmOwner = Ownable2Step(m.ctm).owner();
        if (ctmOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(m.ctm, ctmOwner);
        }
        address proxyAdminOwner = m.ctmProxyAdmin.owner();
        if (proxyAdminOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(address(m.ctmProxyAdmin), proxyAdminOwner);
        }

        RegistryAuthorityLib.requireExecutorsBound(_authority(m));

        // The departing version fixes which ecosystem this edge is valid for.
        uint256 liveVersion = IChainTypeManager(m.ctm).protocolVersion();
        if (liveVersion != m.expectedProtocolVersion) {
            revert OutdatedProtocolVersion(liveVersion, m.expectedProtocolVersion);
        }

        // Checked before the rows: a notifier still under its old administrator cannot be read
        // through `ctmProxyAdmin` at all.
        RegistryAuthorityLib.requireNotifierHandedOver(_authority(m));

        // Every implementation swap is source-checked: replaying a stale migration, or running it
        // against an ecosystem someone already moved, cannot silently re-point a proxy. A row
        // already at `implNew` is fine — `applyRows` skips it.
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(m.ctmProxyUpgrades, CTM_CONTRACT_COUNT);
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            ProxyUpgradeRow memory row = rows[i];
            address liveImpl = m.ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(row.proxy));
            if (liveImpl != row.expectedOldImpl && liveImpl != row.implNew) {
                revert ProxyUpgradeRowMismatch(row.proxy, row.expectedOldImpl, liveImpl);
            }
            ObjectAnchorLib.requireCode(row.implNew);
        }

        ObjectAnchorLib.requireCode(m.upgradeEngine);
        if (m.l2Plan.delegateComposer != address(0)) {
            ObjectAnchorLib.requireCode(m.l2Plan.delegateComposer);
        }
        // The composed L2 transaction must find every bytecode it depends on already published
        // on the CTM's supplier, or the edge fails on every chain's L2 leg.
        L2PlanLib.requirePublished(
            BytecodesSupplier(IChainTypeManager(m.ctm).L1_BYTECODES_SUPPLIER()),
            l2Plan().factoryDepHashes
        );

        ObjectAnchorLib.requireCode(m.currentRelease);
        ICTMRelease(m.currentRelease).validate();
    }

    /// @notice Reverts unless the edge COMPLETED: `migrate()` ran, the CTM sits at the new version
    ///         with the named release installed, the whole CTM domain — the ServerNotifier
    ///         included — is held by the CTM executor, and both domains' executors are governed and
    ///         bound as the manifest names with no ownership nomination outstanding on any authority
    ///         the edge hands over or drives. The last call of the bootstrap bundle, so a failing
    ///         check reverts the whole edge.
    /// @dev The proxy rows are not re-read: `migrate()` verified them in the transaction that
    ///      applied them. The version/release check does describe this one edge: a later
    ///      transition moves the CTM on, after which this reverts by design.
    function validateApplied() external view {
        if (!executed) {
            revert BootstrapNotYetExecuted();
        }
        BootstrapManifest memory m = getManifest();

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        uint256 liveVersion = ctm.protocolVersion();
        if (liveVersion != derivedNewProtocolVersion) {
            revert OutdatedProtocolVersion(liveVersion, derivedNewProtocolVersion);
        }
        address liveRelease = ctm.currentRelease();
        if (liveRelease != m.currentRelease) {
            revert BootstrapReleaseNotInstalled(m.currentRelease, liveRelease);
        }

        // The whole CTM domain must have LANDED under the bound executor — the accept inside
        // `migrate()` completed, nothing is parked on this spent object — in the shape a fresh
        // deployment is born with.
        RegistryAuthorityLib.requireRegistryAuthority(_authority(m));
    }

    /// @param _m The manifest.
    /// @return The authority shape the manifest names.
    function _authority(BootstrapManifest memory _m) private pure returns (RegistryAuthorityLib.Authority memory) {
        return
            RegistryAuthorityLib.Authority({
                ctm: _m.ctm,
                ctmProxyAdmin: _m.ctmProxyAdmin,
                serverNotifier: _m.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].proxy,
                ctmExecutor: _m.ctmExecutor,
                coreExecutor: _m.coreExecutor,
                coordinator: _m.coordinator,
                governance: _m.governance
            });
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
        executed = true;
        BootstrapManifest memory m = getManifest();
        // The CTM is `Ownable2Step`: governance's `transferOwnership` only nominated this contract,
        // so claim it here. Doing it inside `migrate` keeps the whole edge — claim, mutate, hand on
        // — in ONE transaction, which is what stops authority resting here between operations.
        if (Ownable2Step(m.ctm).pendingOwner() == address(this)) {
            Ownable2Step(m.ctm).acceptOwnership();
        }
        validate();

        ProxyUpgradeRowLib.applyRows(
            m.ctmProxyAdmin,
            ProxyUpgradeRowLib.toRows(m.ctmProxyUpgrades, CTM_CONTRACT_COUNT)
        );

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        // The cut-taking form, not `setNewVersionUpgradeFromTransition`: there is no transition for
        // this edge to derive from. Chains crossing it therefore use the cut-taking chain-side
        // entrypoint too — `upgradeTransition` stays zero for the departing version, and only
        // registry-driven hops after this one populate it. It installs the genesis release in the
        // same call, at the release's own version.
        ctm.setNewVersionUpgrade({
            _cutData: upgradeCut(),
            _oldProtocolVersion: m.expectedProtocolVersion,
            _oldProtocolVersionDeadline: m.oldProtocolVersionDeadline,
            _newRelease: m.currentRelease
        });

        // Authority leaves in the same transaction it arrived. The ProxyAdmin is plain `Ownable`,
        // so its transfer lands immediately. The CTM is `Ownable2Step`: nominate the executor and
        // complete the handover through its `acceptCTMOwnership()` in the SAME transaction — the
        // accept is permissionless-safe (see its docs), so the CTM never sits owned by this
        // spent one-shot object waiting for a separate governance call.
        Ownable2Step(m.ctm).transferOwnership(m.ctmExecutor);
        m.ctmProxyAdmin.transferOwnership(m.ctmExecutor);
        CTMUpgradeExecutor(payable(m.ctmExecutor)).acceptCTMOwnership();

        emit EcosystemBootstrapped(m.ctm, m.currentRelease, derivedNewProtocolVersion);
    }
}
