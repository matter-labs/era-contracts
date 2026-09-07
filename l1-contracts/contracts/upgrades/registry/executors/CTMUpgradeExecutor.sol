// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "./EcosystemUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../../core/chain-asset-handler/IChainAssetHandler.sol";
import {GovernanceUpgradeTimer} from "../../GovernanceUpgradeTimer.sol";
import {
    CTMExecutorNotAuthorized,
    EmptyBytes32,
    EcosystemExecutorProxyAdminMismatch,
    MigrationsNotPaused,
    TimerNotBoundToExecutor,
    TransitionNotCommitted,
    TransitionNotPending,
    TransitionReleaseMismatch,
    UpgradeLifecycleBusy,
    UpgradeNotPermissionlessYet,
    UpgradeStageOutOfOrder,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {L2PlanValidationLib} from "../libraries/L2PlanValidationLib.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor BOUND to one immutable ChainTypeManager: it owns that CTM
///         and drives every protocol upgrade of it as a three-stage lifecycle over a pinned,
///         write-once `CTMTransition` — `stage0` (prepare), `stage1` (execute), `stage2`
///         (complete) — plus the per-chain `upgradeChain`. The stage bodies are the governance
///         stages the prepare scripts used to compose as calldata, moved into audited code; the
///         inventory of what each stage does is {docs/upgrade-stage-lifecycle.md}. CTM authority
///         is deliberately separate from ecosystem authority (`EcosystemUpgradeExecutor`): the
///         ecosystem leg of an upgrade runs through THAT executor, under an explicit
///         authorization, for exactly the registry the transition names.
/// @dev Fixed logic, no generic delegatecall. The transition each stage takes is a *pinned
///      implementation address* — the exact generated contract governance approved — never a
///      proxy. Stage inputs are the transition, this executor's bound contracts and protocol
///      getters; no caller-supplied calldata enters a stage. The CTM's routine and recovery owner
///      operations that have NO chain-side alternative (the chain gates them
///      `onlyChainTypeManager`) are exposed as fixed passthroughs below. Deliberately NOT passed
///      through: the legacy cut-taking commits and `executeUpgrade` (an arbitrary cut — the very
///      bypass the object-driven path exists to remove) and the release-provenance setters
///      (driven by `stage1` and the bootstrap only).
contract CTMUpgradeExecutor is UpgradeExecutorBase, ICTMUpgradeExecutor {
    using CodehashPinLib for address;

    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies under the CTM's own administration. Owned by this executor, so a
    ///         transition's `ctmProxyRows` (including the CTM's own implementation swap) apply
    ///         through the same authority that commits the transition. Deliberately NOT the
    ///         ecosystem `ProxyAdmin`: a CTM is one of possibly many and upgrades on its own
    ///         cadence, so nothing CTM-scoped sits under ecosystem authority.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    /// @notice The ecosystem's executor, through which the ecosystem leg of a transition (its
    ///         `coreRegistry`) is applied and verified. Bound here rather than read live: a
    ///         transparent proxy's admin is not readable on-chain by a non-admin, so "the owner of
    ///         the Bridgehub's ProxyAdmin" cannot be derived — it must be configured.
    ///         Governance may replace it between upgrades, retaining the same ecosystem admin.
    EcosystemUpgradeExecutor public ECOSYSTEM_EXECUTOR;

    /// @notice `EXTCODEHASH` of the audited `CTMTransition`. Every transition this executor accepts
    ///         must run exactly that code — which, since the manifest is written in the constructor
    ///         and no setter exists, makes "canonical write-once object" an on-chain invariant: an
    ///         arbitrary contract (or upgradeable proxy) merely implementing `ICTMTransition` is
    ///         rejected. Manifest CONTENT is not gated here and never was; governance approving the
    ///         address is what gates content.
    bytes32 public immutable TRANSITION_CODEHASH;

    /// @inheritdoc ICTMUpgradeExecutor
    ICTMTransition public pendingTransition;

    /// @inheritdoc ICTMUpgradeExecutor
    UpgradeStage public pendingStage;

    /// @notice Emitted by `stage0`: the transition is recorded, chain migrations are held paused
    ///         and the transition's timer is running until `deadline`.
    event UpgradePrepared(address indexed transition, uint256 deadline);

    /// @notice Emitted by `stage1` after the ecosystem leg (if any) and the CTM leg were applied.
    event UpgradeExecuted(address indexed transition);

    /// @notice Emitted by `stage2` after the completion checks passed and the migration pause held
    ///         for this upgrade was released.
    event UpgradeCompleted(address indexed transition);

    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    constructor(
        address _initialOwner,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin,
        EcosystemUpgradeExecutor _ecosystemExecutor,
        bytes32 _transitionCodehash
    ) UpgradeExecutorBase(_initialOwner) {
        if (
            address(_ctm) == address(0) ||
            address(_ctmProxyAdmin) == address(0) ||
            address(_ecosystemExecutor) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_transitionCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        CHAIN_TYPE_MANAGER = _ctm;
        CTM_PROXY_ADMIN = _ctmProxyAdmin;
        ECOSYSTEM_EXECUTOR = _ecosystemExecutor;
        TRANSITION_CODEHASH = _transitionCodehash;
    }

    /// @notice Emitted when governance replaces the ecosystem executor between upgrades.
    event EcosystemExecutorChanged(address indexed previousExecutor, address indexed newExecutor);

    /// @notice Rebinds to a successor for the same ecosystem ProxyAdmin.
    /// @dev Ownership transfer and authorization are explicit governance actions. A pending
    /// transition must finish first so preparation, execution and checks use one executor.
    function setEcosystemExecutor(EcosystemUpgradeExecutor _newExecutor) external onlyOwner {
        if (address(pendingTransition) != address(0)) {
            revert UpgradeLifecycleBusy(address(pendingTransition));
        }
        if (address(_newExecutor) == address(0)) {
            revert ZeroAddress();
        }
        address expectedAdmin = address(ECOSYSTEM_EXECUTOR.PROXY_ADMIN());
        address actualAdmin = address(_newExecutor.PROXY_ADMIN());
        if (actualAdmin != expectedAdmin) {
            revert EcosystemExecutorProxyAdminMismatch(expectedAdmin, actualAdmin);
        }
        address previousExecutor = address(ECOSYSTEM_EXECUTOR);
        ECOSYSTEM_EXECUTOR = _newExecutor;
        emit EcosystemExecutorChanged(previousExecutor, address(_newExecutor));
    }

    /// @dev Type provenance: the object at `_transition` must run the audited `CTMTransition` code.
    function _requireGenuineTransition(ICTMTransition _transition) private view {
        address(_transition).requirePin(TRANSITION_CODEHASH);
    }

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev A narrow, fixed entrypoint so the standard handover does not depend on break-glass.
    /// @dev Deliberately PERMISSIONLESS: it can only ever accept ownership of the BOUND CTM, and
    ///      only after that CTM's current owner nominated this executor — the nomination is the
    ///      approval, exactly the gate that makes `RegistryBootstrapMigration.migrate()`
    ///      permissionless. That is also what lets the bootstrap migration complete the handover
    ///      inside `migrate()` itself, so authority is never parked between bundle calls.
    function acceptCTMOwnership() external {
        Ownable2Step(address(CHAIN_TYPE_MANAGER)).acceptOwnership();
    }

    /// @notice Moves a departed protocol version's deadline on the bound CTM.
    /// @dev A fixed entrypoint rather than break-glass: the deadline is routine operational state
    ///      that keeps changing after a transition commits (extended while chains lag, shortened
    ///      to retire a version), and the transition's pinned value is only its starting point.
    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external onlyOwner {
        CHAIN_TYPE_MANAGER.setProtocolVersionDeadline(_protocolVersion, _timestamp);
    }

    // ---------------------------------------------------------------------------------------
    // Routine operational and recovery passthroughs — the CTM owner surface with no chain-side
    // alternative. One argument list each, forwarded verbatim; the CTM keeps every check.
    // ---------------------------------------------------------------------------------------

    /// @notice Freezes a chain diamond (incident response).
    function freezeChain(uint256 _chainId) external onlyOwner {
        CHAIN_TYPE_MANAGER.freezeChain(_chainId);
    }

    /// @notice Unfreezes a chain diamond.
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        CHAIN_TYPE_MANAGER.unfreezeChain(_chainId);
    }

    /// @notice Reverts a chain's batches down to `_newLastBatch` — governance recovery when the
    ///         validator that could otherwise do it is the problem.
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwner {
        CHAIN_TYPE_MANAGER.revertBatches(_chainId, _newLastBatch);
    }

    /// @notice Adds or removes a chain validator.
    function setValidator(uint256 _chainId, address _validator, bool _active) external onlyOwner {
        CHAIN_TYPE_MANAGER.setValidator(_chainId, _validator, _active);
    }

    /// @notice Sets a chain's priority transaction gas limit cap.
    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external onlyOwner {
        CHAIN_TYPE_MANAGER.setPriorityTxMaxGasLimit(_chainId, _maxGasLimit);
    }

    /// @notice Sets a chain's zkPorter availability flag.
    function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external onlyOwner {
        CHAIN_TYPE_MANAGER.setPorterAvailability(_chainId, _zkPorterIsAvailable);
    }

    /// @notice Deactivates priority mode on a chain.
    function deactivatePriorityMode(uint256 _chainId) external onlyOwner {
        CHAIN_TYPE_MANAGER.deactivatePriorityMode(_chainId);
    }

    /// @notice Points the CTM at a new post-v29 validator timelock.
    function setValidatorTimelockPostV29(address _validatorTimelockPostV29) external onlyOwner {
        CHAIN_TYPE_MANAGER.setValidatorTimelockPostV29(_validatorTimelockPostV29);
    }

    // ---------------------------------------------------------------------------------------
    // The three-stage lifecycle. One transition at a time; each stage names the transition and
    // is rejected for a different one, out of order, or twice.
    // ---------------------------------------------------------------------------------------

    /// @notice Stage 0 — preparation. Validates the transition (pins, both edges, the ecosystem
    ///         leg it names), records it as pending, holds chain migrations paused and starts the
    ///         transition's timer.
    /// @dev Everything that can be rejected is rejected BEFORE the transition is recorded, so a
    ///      wrong object never occupies the lifecycle slot. The migration pause is a HOLD of this
    ///      executor's own on the shared ChainAssetHandler — it composes with other upgrades'
    ///      holds and with the owner's pause, and it is what makes the CTM's version commit in
    ///      stage 1 admissible.
    /// @param _transition The write-once transition approved by governance.
    function stage0(ICTMTransition _transition) external onlyOwner {
        if (address(pendingTransition) != address(0)) {
            revert UpgradeLifecycleBusy(address(pendingTransition));
        }
        _requireGenuineTransition(_transition);
        _transition.validate();
        _requireEdges(_transition);
        // The ecosystem leg runs through the ecosystem executor, so this executor must be wired
        // there, and the registry the transition names must be a genuine audited object.
        if (!ECOSYSTEM_EXECUTOR.isAuthorizedCTMExecutor(address(this))) {
            revert CTMExecutorNotAuthorized(address(this));
        }
        address coreRegistry = _transition.coreRegistry();
        if (coreRegistry != address(0)) {
            coreRegistry.requirePin(ECOSYSTEM_EXECUTOR.CORE_REGISTRY_CODEHASH());
            ICoreRegistry(coreRegistry).validate();
        }
        // A timer nobody else can start — and one this executor can, which `startTimer` below
        // would only prove after the pause is already held.
        GovernanceUpgradeTimer timer = GovernanceUpgradeTimer(_transition.upgradeTimer());
        address timerGovernance = timer.TIMER_GOVERNANCE();
        if (timerGovernance != address(this)) {
            revert TimerNotBoundToExecutor(address(timer), timerGovernance);
        }

        pendingTransition = _transition;
        pendingStage = UpgradeStage.Prepared;

        _chainAssetHandler().acquireMigrationPause();
        timer.startTimer();
        emit UpgradePrepared(address(_transition), timer.deadline());
    }

    /// @notice Stage 1 — execution. Requires the prepared transition, its timer's deadline and a
    ///         paused migration state; applies the ecosystem leg (when named) THEN the CTM leg:
    ///         CTM-domain proxy rows, the version commit and the release pin. Any failure reverts
    ///         the whole stage.
    /// @param _transition The transition prepared by `stage0`.
    function stage1(ICTMTransition _transition) external onlyOwner {
        _requirePending(_transition, UpgradeStage.Prepared);
        GovernanceUpgradeTimer(_transition.upgradeTimer()).checkDeadline();
        // Checked here for a clear failure; the CTM's own version commit refuses to run unpaused.
        if (!_chainAssetHandler().migrationPaused()) {
            revert MigrationsNotPaused();
        }
        // Ecosystem leg first — the order the merged governance bundle always had: the CTM leg
        // may depend on shared singletons already running their new implementations.
        address coreRegistry = _transition.coreRegistry();
        if (coreRegistry != address(0)) {
            ECOSYSTEM_EXECUTOR.applyL1Upgrade(ICoreRegistry(coreRegistry));
        }
        _applyCTMUpgrade(_transition);
        pendingStage = UpgradeStage.Executed;
        emit UpgradeExecuted(address(_transition));
    }

    /// @notice Stage 2 — completion. Requires the executed transition; runs the applied-state
    ///         checks for both legs, then releases the migration pause held since `stage0` and
    ///         clears the lifecycle slot.
    /// @dev Completion checks come BEFORE restoration: a failed check leaves migrations paused
    ///      and the lifecycle open. Stage 2 means exactly this — the L1 edge is complete and the
    ///      operational restrictions are lifted; it does not attest that every chain has finished
    ///      its own upgrade.
    /// @param _transition The transition executed by `stage1`.
    function stage2(ICTMTransition _transition) external onlyOwner {
        _requirePending(_transition, UpgradeStage.Executed);
        _requireTransitionApplied(_transition);
        address coreRegistry = _transition.coreRegistry();
        if (coreRegistry != address(0)) {
            ECOSYSTEM_EXECUTOR.validateUpgradeApplied(ICoreRegistry(coreRegistry));
        }
        delete pendingTransition;
        pendingStage = UpgradeStage.None;
        _chainAssetHandler().releaseMigrationPause();
        emit UpgradeCompleted(address(_transition));
    }

    /// @notice Reverts unless `_transition` has been APPLIED on the bound CTM: it is the
    ///         committed transition for its version edge, the CTM has moved to (at least) its new
    ///         version, and every CTM-domain proxy row points at its pinned `implNew`, read live
    ///         through the bound `ProxyAdmin`. The CTM-leg half of the stage-2 check, exposed for
    ///         tooling and for the bootstrap edge's verification.
    /// @dev The row check describes one edge, not a standing invariant: a later upgrade moves
    ///      proxies past these rows and this then reverts by design.
    function validateTransitionApplied(ICTMTransition _transition) external view {
        _requireGenuineTransition(_transition);
        _requireTransitionApplied(_transition);
    }

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `stage1` committed to.
    /// @dev Execution policy, in order of precedence:
    ///      - the OWNER may upgrade any chain at any time;
    ///      - a CHAIN'S OWN ADMIN may upgrade that chain at any time — upgrading is the chain's
    ///        decision to make, and the check is scoped per chain because `_chainId` is an
    ///        argument: an unscoped admin check would let any chain's admin upgrade every other
    ///        chain on this CTM, including ones deliberately waiting to finalize batches first;
    ///      - ANYONE ELSE only once the old-version deadline has passed, at which point the
    ///        upgrade is operationally mandatory and execution carries no discretionary inputs.
    ///      The chain-side `upgradeTimestamp` gate applies to non-admin callers regardless.
    /// @param _transition The same transition committed by `stage1`.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            uint256 deadline = CHAIN_TYPE_MANAGER.protocolVersionDeadline(oldProtocolVersion);
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        // The chain executes the cut its own CTM committed, so `_transition` must BE that
        // transition — otherwise the argument would name one edge while a different one ran.
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        // Deliberately NOT re-checked here — do not "restore" this:
        //   - `validate()` re-reads pins that cannot have moved: an `EXTCODEHASH` is fixed for a
        //     non-selfdestructible contract, so anything true at `stage1` is still true.
        //     It also costs ~19 EXTCODEHASH reads across both releases, PER CHAIN, on a function
        //     that is permissionless once the deadline passes.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);
        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev The lifecycle gate every stage after 0 shares: the named transition is the pending
    ///      one and it sits exactly one stage back.
    function _requirePending(ICTMTransition _transition, UpgradeStage _expected) private view {
        if (address(pendingTransition) != address(_transition)) {
            revert TransitionNotPending(address(_transition), address(pendingTransition));
        }
        if (pendingStage != _expected) {
            revert UpgradeStageOutOfOrder(uint8(pendingStage), uint8(_expected));
        }
    }

    /// @dev Both transition edges, asserted independently:
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since stage 1 moves `currentRelease` — rejects replays;
    ///      - the version edge (`protocolVersion == oldProtocolVersion`) rejects the wrong
    ///        version schedule (also re-checked inside `setNewVersionUpgradeFromTransition`).
    function _requireEdges(
        ICTMTransition _transition
    ) private view returns (uint256 oldProtocolVersion, uint256 newProtocolVersion) {
        address currentRelease = CHAIN_TYPE_MANAGER.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }
        oldProtocolVersion = _transition.oldProtocolVersion();
        newProtocolVersion = _transition.newProtocolVersion();
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion != oldProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, oldProtocolVersion);
        }
    }

    /// @dev The CTM leg of stage 1: installs the transition and points new-chain genesis at its
    ///      target release. Internal by design — the lifecycle cannot be bypassed.
    function _applyCTMUpgrade(ICTMTransition _transition) private {
        _transition.validate();
        (uint256 oldProtocolVersion, uint256 newProtocolVersion) = _requireEdges(_transition);
        // Every bytecode the L2 transaction depends on must already be published on the CTM's
        // supplier — otherwise the committed edge fails on every chain's L2 leg.
        L2PlanValidationLib.requirePublished(
            BytecodesSupplier(CHAIN_TYPE_MANAGER.L1_BYTECODES_SUPPLIER()),
            _transition.l2Plan().factoryDepHashes
        );
        // CTM-domain implementation swaps FIRST — the commit below may need setters that only
        // exist on the implementation this very transition installs (the bootstrap's
        // "ordering is load-bearing" rule, made permanent).
        ProxyUpgradeRowLib.applyRows(CTM_PROXY_ADMIN, _transition.ctmProxyRows());
        // One argument, not four plus a cut: the CTM reads the version edge, the schedule and the
        // cut from the same pinned object, so they cannot be passed inconsistently.
        CHAIN_TYPE_MANAGER.setNewVersionUpgradeFromTransition(_transition);
        CHAIN_TYPE_MANAGER.setCurrentRelease(_transition.newRelease());
        emit CTMUpgradeApplied(address(_transition), oldProtocolVersion, newProtocolVersion);
    }

    function _requireTransitionApplied(ICTMTransition _transition) private view {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        uint256 newProtocolVersion = _transition.newProtocolVersion();
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion < newProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, newProtocolVersion);
        }
        ProxyUpgradeRowLib.requireRowsApplied(CTM_PROXY_ADMIN, _transition.ctmProxyRows());
    }

    /// @dev The shared ChainAssetHandler, read from the bound CTM's Bridgehub.
    function _chainAssetHandler() private view returns (IChainAssetHandlerBase) {
        return IChainAssetHandlerBase(IBridgehubBase(CHAIN_TYPE_MANAGER.BRIDGE_HUB()).chainAssetHandler());
    }
}
