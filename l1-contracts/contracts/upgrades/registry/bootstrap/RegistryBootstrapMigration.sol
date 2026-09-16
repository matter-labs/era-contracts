// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {CTM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {IEcosystemUpgradeExecutor} from "../executors/IEcosystemUpgradeExecutor.sol";
import {CTMUpgradeExecutor} from "../executors/CTMUpgradeExecutor.sol";
import {ICommittedUpgrade} from "../objects/ICommittedUpgrade.sol";
import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../../core/chain-asset-handler/IChainAssetHandler.sol";
import {GovernanceUpgradeTimer} from "../../GovernanceUpgradeTimer.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {IRegistryBootstrapMigration} from "./IRegistryBootstrapMigration.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    BootstrapExecutorOwnerMismatch,
    BootstrapExecutorOwnershipPending,
    BootstrapNotYetExecuted,
    BootstrapReleaseNotInstalled,
    MigrationPaused,
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
contract RegistryBootstrapMigration is IRegistryBootstrapMigration {
    /// @notice Set once `migrate` has run. The edge is one-shot: replaying it would re-check a
    ///         starting state that no longer exists anyway, but failing loudly is clearer.
    bool public executed;

    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    /// @dev The FINAL L2 plan, constructed at construction and stored as its ABI encoding (see
    ///      {CTMTransition} for why).
    bytes internal encodedL2Plan;

    /// @notice Stores the audited manifest at construction; it is immutable afterwards.
    constructor(BootstrapManifest memory _manifest) {
        if (
            _manifest.ctm == address(0) ||
            address(_manifest.ctmProxyAdmin) == address(0) ||
            _manifest.currentRelease == address(0) ||
            _manifest.ctmExecutor == address(0) ||
            _manifest.ctmExecutorOwner == address(0) ||
            _manifest.coordinator == address(0) ||
            _manifest.upgradeTimer == address(0) ||
            _manifest.upgradeEngine == address(0)
        ) {
            revert ZeroAddress();
        }
        // An edge with no implementation swaps is not a bootstrap; it would silently reduce to
        // "install anchors and hand over authority", which is a different (unreviewed) operation.
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(_manifest.proxyUpgrades, CTM_CONTRACT_COUNT);
        if (rows.length == 0) {
            revert RegistryUnknownKey();
        }
        // Same row discipline as {CoreRegistry} and {CTMTransition} (shared lib).
        ProxyUpgradeRowLib.validateRows(rows);
        // The L2 leg, exactly as a transition constructs it: the genesis release's table (the target
        // state, installed in full — there is no departing release to diff against) plus the
        // authored delegate and extras, with the same shape rules ({L2PlanLib.build}).
        ICTMRelease release = ICTMRelease(_manifest.currentRelease);
        encodedL2Plan = abi.encode(
            L2PlanLib.build(
                TransitionDerivationLib.deriveL2DeploymentsFromTable(
                    release.l2BytecodeInfos(),
                    release.l2SystemProxyBytecodeInfo()
                ),
                _manifest.l2Plan
            )
        );
        encodedManifest = abi.encode(_manifest);
    }

    /// @notice Commitment to the whole manifest — the 32 bytes governance approves. Computed
    ///         from the stored encoding; no contract reads it.
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @inheritdoc IRegistryBootstrapMigration
    function getManifest() public view returns (BootstrapManifest memory) {
        return abi.decode(encodedManifest, (BootstrapManifest));
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev The genesis release is the edge's target: a chain crossing this edge after the CTM has
    ///      moved on still installs the release ITS OWN committed migration names.
    function upgradeTarget() external view returns (uint256, uint256, address) {
        BootstrapManifest memory m = getManifest();
        return (m.newProtocolVersion, m.upgradeTimestamp, m.currentRelease);
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
                _newProtocolVersion: m.newProtocolVersion,
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
    ///         AND the edge is executable now: the named timer's operational window has passed
    ///         (which also proves stage 0 started it — `checkDeadline` rejects an unstarted timer).
    /// @dev Runs on the execution path, so a drifted ecosystem cannot be migrated by accident and
    ///      the stage sequencing is enforced by the object itself, not by call order in a bundle.
    /// @dev NOT a complete precondition oracle: `setNewVersionUpgrade` additionally requires chain
    ///      migrations to be paused — ecosystem-domain state governance pauses in stage 0, enforced
    ///      on-chain by the CTM's own version-edge commit rather than pinned here.
    function validate() public view {
        BootstrapManifest memory m = getManifest();

        ObjectAnchorLib.requireCode(m.upgradeTimer);
        GovernanceUpgradeTimer(m.upgradeTimer).checkDeadline();

        // Authority must already rest here, or `migrate` could not perform any of the work.
        address ctmOwner = Ownable2Step(m.ctm).owner();
        if (ctmOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(m.ctm, ctmOwner);
        }
        address proxyAdminOwner = m.ctmProxyAdmin.owner();
        if (proxyAdminOwner != address(this)) {
            revert BootstrapAuthorityNotHeld(address(m.ctmProxyAdmin), proxyAdminOwner);
        }

        // The executors are where ALL of this authority ends up, so every binding they carry is
        // checked BY VALUE against the very contracts they receive. An executor bound elsewhere
        // would take ownership its fixed entrypoints cannot drive — and since the edge is
        // one-shot, recovering from that would mean falling back to break-glass, the one
        // authority this design exists to avoid depending on.
        ObjectAnchorLib.requireCode(m.ctmExecutor);
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(m.ctmExecutor));
        // Ownership is storage, so it is checked here rather than assumed from the reviewed
        // deployment: an executor whose ownership moved after deployment would otherwise pass
        // every other check and then receive the whole CTM domain on behalf of whoever owns it
        // now.
        address executorOwner = ctmExecutor.owner();
        if (executorOwner != m.ctmExecutorOwner) {
            revert BootstrapExecutorOwnerMismatch(m.ctmExecutorOwner, executorOwner);
        }
        // A nomination outstanding at handover time is the same hole one step removed: the
        // nominee could accept immediately after `migrate()` and inherit the domain.
        address executorPendingOwner = ctmExecutor.pendingOwner();
        if (executorPendingOwner != address(0)) {
            revert BootstrapExecutorOwnershipPending(executorPendingOwner);
        }
        // The coordinator every later operation on this CTM is driven by.
        address boundCoordinator = ctmExecutor.coordinator();
        if (boundCoordinator != m.coordinator) {
            revert BootstrapExecutorNotBound(m.ctmExecutor, m.coordinator, boundCoordinator);
        }
        address boundCtm = address(ctmExecutor.CHAIN_TYPE_MANAGER());
        if (boundCtm != m.ctm) {
            revert BootstrapExecutorNotBound(m.ctmExecutor, m.ctm, boundCtm);
        }
        // The WHOLE CTM domain lands under the one CTM-bound executor: the CTM proxy and its
        // per-CTM proxies share `ctmProxyAdmin`, and later transitions apply their
        // `ctmProxyRows` through it. Nothing CTM-scoped goes under ecosystem authority.
        address boundProxyAdmin = address(ctmExecutor.CTM_PROXY_ADMIN());
        if (boundProxyAdmin != address(m.ctmProxyAdmin)) {
            revert BootstrapExecutorNotBound(m.ctmExecutor, address(m.ctmProxyAdmin), boundProxyAdmin);
        }

        // The departing version fixes which ecosystem this edge is valid for.
        uint256 liveVersion = IChainTypeManager(m.ctm).protocolVersion();
        if (liveVersion != m.expectedProtocolVersion) {
            revert OutdatedProtocolVersion(liveVersion, m.expectedProtocolVersion);
        }

        // Every implementation swap is source-checked: replaying a stale migration, or running it
        // against an ecosystem someone already moved, cannot silently re-point a proxy. A row
        // already at `implNew` is fine — `applyRows` skips it — which is how a row a different
        // administrator applied first (the ServerNotifier's CTM-admin call) passes.
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(m.proxyUpgrades, CTM_CONTRACT_COUNT);
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            ProxyUpgradeRow memory row = rows[i];
            address liveImpl = ProxyUpgradeRowLib.adminOf(m.ctmProxyAdmin, row).getProxyImplementation(
                ITransparentUpgradeableProxy(row.proxy)
            );
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

    /// @notice Reverts unless the edge has been APPLIED end to end: `migrate()` ran, the CTM sits
    ///         at the new version with the named release and anchor installed, every proxy row
    ///         points at its `implNew`, the whole CTM domain is owned by the bound
    ///         executor, and the CTM's chain migrations are no longer paused. The stage-2 gate
    ///         for the bundle whose stage 1 ran `migrate()` — deeper than a bare version check,
    ///         and readable by any tooling afterwards.
    /// @dev The row check describes this one edge: a later transition legitimately moves the
    ///      CTM-domain proxies (and `currentRelease`) on, after which this reverts by design.
    function validateApplied() external view {
        if (!executed) {
            revert BootstrapNotYetExecuted();
        }
        BootstrapManifest memory m = getManifest();

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        uint256 liveVersion = ctm.protocolVersion();
        if (liveVersion != m.newProtocolVersion) {
            revert OutdatedProtocolVersion(liveVersion, m.newProtocolVersion);
        }
        address liveRelease = ctm.currentRelease();
        if (liveRelease != m.currentRelease) {
            revert BootstrapReleaseNotInstalled(m.currentRelease, liveRelease);
        }

        ProxyUpgradeRowLib.requireRowsApplied(
            m.ctmProxyAdmin,
            ProxyUpgradeRowLib.toRows(m.proxyUpgrades, CTM_CONTRACT_COUNT)
        );

        // The whole CTM domain must have LANDED under the bound executor — the accept inside
        // `migrate()` completed, nothing is parked on this spent object.
        address ctmOwner = Ownable2Step(m.ctm).owner();
        if (ctmOwner != m.ctmExecutor) {
            revert BootstrapAuthorityNotHeld(m.ctm, ctmOwner);
        }
        address proxyAdminOwner = m.ctmProxyAdmin.owner();
        if (proxyAdminOwner != m.ctmExecutor) {
            revert BootstrapAuthorityNotHeld(address(m.ctmProxyAdmin), proxyAdminOwner);
        }
        address boundExecutor = address(IEcosystemUpgradeExecutor(m.coordinator).ctmExecutor());
        if (boundExecutor != m.ctmExecutor) {
            revert BootstrapExecutorNotBound(m.coordinator, m.ctmExecutor, boundExecutor);
        }
        // Completion lifts the operational restrictions too: the stage-0 pause must have been
        // released before this edge counts as done, so the bundle cannot forget it.
        IChainAssetHandlerBase chainAssetHandler = IChainAssetHandlerBase(
            IBridgehubBase(ctm.BRIDGE_HUB()).chainAssetHandler()
        );
        if (chainAssetHandler.migrationPausedFor(m.ctm)) {
            revert MigrationPaused();
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
        executed = true;
        BootstrapManifest memory m = getManifest();
        // The CTM is `Ownable2Step`: governance's `transferOwnership` only nominated this contract,
        // so claim it here. Doing it inside `migrate` keeps the whole edge — claim, mutate, hand on
        // — in ONE transaction, which is what stops authority resting here between operations.
        if (Ownable2Step(m.ctm).pendingOwner() == address(this)) {
            Ownable2Step(m.ctm).acceptOwnership();
        }
        validate();

        ProxyUpgradeRowLib.applyRows(m.ctmProxyAdmin, ProxyUpgradeRowLib.toRows(m.proxyUpgrades, CTM_CONTRACT_COUNT));

        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        // The cut-taking form, not `setNewVersionUpgradeFromTransition`: there is no transition for
        // this edge to derive from. Chains crossing it therefore use the cut-taking chain-side
        // entrypoint too — `upgradeTransition` stays zero for the departing version, and only
        // registry-driven hops after this one populate it.
        ctm.setNewVersionUpgrade({
            _cutData: upgradeCut(),
            _oldProtocolVersion: m.expectedProtocolVersion,
            _oldProtocolVersionDeadline: m.oldProtocolVersionDeadline,
            _newProtocolVersion: m.newProtocolVersion
        });
        ctm.setCurrentRelease(m.currentRelease);

        // Authority leaves in the same transaction it arrived. The ProxyAdmin is plain `Ownable`,
        // so its transfer lands immediately. The CTM is `Ownable2Step`: nominate the executor and
        // complete the handover through its `acceptCTMOwnership()` in the SAME transaction — the
        // accept is permissionless-safe (see its docs), so the CTM never sits owned by this
        // spent one-shot object waiting for a separate governance call.
        Ownable2Step(m.ctm).transferOwnership(m.ctmExecutor);
        m.ctmProxyAdmin.transferOwnership(m.ctmExecutor);
        CTMUpgradeExecutor(payable(m.ctmExecutor)).acceptCTMOwnership();

        emit EcosystemBootstrapped(m.ctm, m.currentRelease, m.newProtocolVersion);
    }
}
