// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../../core/chain-asset-handler/IChainAssetHandler.sol";
import {
    EmptyBytes32,
    MigrationsNotPaused,
    NoPendingOperation,
    ExecutorCoordinatorMismatch,
    TransitionNotCommitted,
    TransitionReleaseMismatch,
    Unauthorized,
    UpgradeLifecycleBusy,
    UpgradeNotPermissionlessYet,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {IEcosystemUpgradeExecutor} from "./IEcosystemUpgradeExecutor.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to one immutable ChainTypeManager: it owns that CTM and its
///         `ProxyAdmin`, and applies pinned, write-once `CTMTransition`s to it on the coordinating
///         `EcosystemUpgradeExecutor`'s instructions — reserve, apply, complete — plus the
///         per-chain `upgradeChain`. See {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The transition each callback takes is an
///      *implementation address* — the exact generated contract governance approved — never a
///      proxy. The CTM's routine and recovery owner operations that have NO chain-side alternative
///      (the chain gates them `onlyChainTypeManager`) are exposed as fixed passthroughs below.
///      Deliberately NOT passed through: the legacy cut-taking commits and `executeUpgrade` (an
///      arbitrary cut — the very bypass the object-driven path exists to remove) and the
///      release-provenance setters (driven by `applyOperation` and the bootstrap only).
contract CTMUpgradeExecutor is UpgradeExecutorBase, ICTMUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies under the CTM's own administration. Owned by this executor, so an
    ///         operation's infrastructure rows apply through the same authority that commits its
    ///         transition.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    /// @inheritdoc ICTMUpgradeExecutor
    bytes32 public immutable TRANSITION_CODEHASH;

    /// @inheritdoc ICTMUpgradeExecutor
    address public coordinator;

    /// @inheritdoc ICTMUpgradeExecutor
    IEcosystemUpgradeOperation public activeOperation;

    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice Emitted by `beginOperation`: the operation's CTM leg is reserved and the CTM's
    ///         chain migrations are paused. `transition` is zero for an infrastructure-only leg.
    event OperationReserved(address indexed operation, address indexed transition);

    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted by `completeOperation`: the reservation is released and migrations resume.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted by `abandonOperation`: the reservation is released, migrations stay paused.
    event OperationAbandoned(address indexed operation);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(
        address _initialOwner,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin,
        address _coordinator,
        bytes32 _transitionCodehash
    ) UpgradeExecutorBase(_initialOwner) {
        if (address(_ctm) == address(0) || address(_ctmProxyAdmin) == address(0) || _coordinator == address(0)) {
            revert ZeroAddress();
        }
        if (_transitionCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        CHAIN_TYPE_MANAGER = _ctm;
        CTM_PROXY_ADMIN = _ctmProxyAdmin;
        coordinator = _coordinator;
        TRANSITION_CODEHASH = _transitionCodehash;
    }

    /// @notice Points this executor at a coordinator (zero detaches it).
    /// @dev Refused while reserved, so one operation is prepared, executed and completed by one
    ///      coordinator.
    function setCoordinator(address _coordinator) external onlyOwner {
        if (address(activeOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(activeOperation));
        }
        emit CoordinatorChanged(coordinator, _coordinator);
        coordinator = _coordinator;
    }

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev Deliberately PERMISSIONLESS: it can only ever accept ownership of the BOUND CTM, and
    ///      only after that CTM's current owner nominated this executor — the nomination is the
    ///      approval. That is what lets `RegistryBootstrapMigration.migrate()` complete the
    ///      handover inside one transaction, so authority is never parked between calls.
    function acceptCTMOwnership() external {
        Ownable2Step(address(CHAIN_TYPE_MANAGER)).acceptOwnership();
    }

    /// @notice Moves a departed protocol version's deadline on the bound CTM.
    /// @dev A fixed entrypoint rather than break-glass: the deadline is routine operational state
    ///      that keeps changing after a transition commits, and the transition's pinned value is
    ///      only its starting point.
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

    /// @notice Deactivates priority mode on a chain.
    function deactivatePriorityMode(uint256 _chainId) external onlyOwner {
        CHAIN_TYPE_MANAGER.deactivatePriorityMode(_chainId);
    }

    /// @notice Points the CTM at a new post-v29 validator timelock.
    function setValidatorTimelockPostV29(address _validatorTimelockPostV29) external onlyOwner {
        CHAIN_TYPE_MANAGER.setValidatorTimelockPostV29(_validatorTimelockPostV29);
    }

    // ---------------------------------------------------------------------------------------
    // The coordinator's callbacks. One operation at a time: `beginOperation` names the operation
    // to reserve, and every callback after it acts on that reservation alone.
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev The coordinator binds this executor; the operation supplies both halves of the leg.
    ///      Migrations are paused for an infrastructure-only leg too — see "Pause policy" in
    ///      {protocol-docs/ecosystem-upgrade-coordination.md}.
    function beginOperation(IEcosystemUpgradeOperation _operation) external onlyCoordinator {
        if (address(activeOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(activeOperation));
        }
        address boundExecutor = address(IEcosystemUpgradeExecutor(coordinator).ctmExecutor());
        if (boundExecutor != address(this)) {
            revert ExecutorCoordinatorMismatch(address(this), boundExecutor);
        }
        ProxyUpgradeRowLib.requireRowCode(_operation.ctmInfrastructureRows());
        ICTMTransition transition = ICTMTransition(_operation.transition());
        if (address(transition) != address(0)) {
            _requireGenuineTransition(transition);
            transition.validate();
            _requireEdges(transition);
        }

        activeOperation = _operation;

        _chainAssetHandler().pauseCTMMigration(address(CHAIN_TYPE_MANAGER));
        emit OperationReserved(address(_operation), address(transition));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function reservedTransition() public view returns (ICTMTransition) {
        if (address(activeOperation) == address(0)) {
            return ICTMTransition(address(0));
        }
        return ICTMTransition(activeOperation.transition());
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev Applies the operation's CTM-domain proxy rows and then, when it carries one, the
    ///      transition's version commit and release pointer. The rows go FIRST — the commit may
    ///      need setters that only exist on the implementation this very operation installs — and
    ///      any failure reverts the coordinator's whole stage, so a failed row leg cannot leave a
    ///      version commit standing.
    function applyOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        // Checked here for a clear failure; the CTM's own version commit refuses to run unpaused.
        if (!_chainAssetHandler().migrationPausedFor(address(CHAIN_TYPE_MANAGER))) {
            revert MigrationsNotPaused();
        }
        ProxyUpgradeRowLib.applyRows(CTM_PROXY_ADMIN, operation.ctmInfrastructureRows());
        ICTMTransition transition = ICTMTransition(operation.transition());
        if (address(transition) != address(0)) {
            _applyCTMUpgrade(transition);
        }
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev This executor releases its own pause only for a leg it can see applied — every
    ///      infrastructure row, and the transition when the operation carries one; the coordinator
    ///      sequences completions and relies on the stage being one transaction.
    function completeOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        ProxyUpgradeRowLib.requireRowsApplied(CTM_PROXY_ADMIN, operation.ctmInfrastructureRows());
        ICTMTransition transition = ICTMTransition(operation.transition());
        if (address(transition) != address(0)) {
            _requireTransitionApplied(transition);
        }
        delete activeOperation;
        _chainAssetHandler().unpauseCTMMigration(address(CHAIN_TYPE_MANAGER));
        emit OperationCompleted(address(operation));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev Whatever `applyOperation` already committed stands — abandoning is bookkeeping, not a
    ///      rollback. Migrations stay paused: whether it is safe to resume them is governance's
    ///      call (`ChainAssetHandler.unpauseCTMMigration` through the fixed CTM authority), not a
    ///      side effect of clearing a slot.
    function abandonOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        delete activeOperation;
        emit OperationAbandoned(address(operation));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function validateTransitionApplied(ICTMTransition _transition) external view {
        _requireGenuineTransition(_transition);
        _requireTransitionApplied(_transition);
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev The row check describes one edge, not a standing invariant: a later upgrade moves
    ///      proxies past these rows and this then reverts by design.
    function validateOperationApplied(IEcosystemUpgradeOperation _operation) external view {
        ProxyUpgradeRowLib.requireRowsApplied(CTM_PROXY_ADMIN, _operation.ctmInfrastructureRows());
        ICTMTransition transition = ICTMTransition(_operation.transition());
        if (address(transition) != address(0)) {
            _requireGenuineTransition(transition);
            _requireTransitionApplied(transition);
        }
    }

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `applyOperation` committed to.
    /// @dev Execution policy, in order of precedence:
    ///      - the OWNER may upgrade any chain at any time;
    ///      - a CHAIN'S OWN ADMIN may upgrade that chain at any time — upgrading is the chain's
    ///        decision to make, and the check is scoped per chain because `_chainId` is an
    ///        argument: an unscoped admin check would let any chain's admin upgrade every other
    ///        chain on this CTM, including ones deliberately waiting to finalize batches first;
    ///      - ANYONE ELSE only once the old-version deadline has passed, at which point the
    ///        upgrade is operationally mandatory and execution carries no discretionary inputs.
    ///      The chain-side `upgradeTimestamp` gate applies to non-admin callers regardless.
    /// @param _transition The same transition committed by `applyOperation`.
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
        // Deliberately NOT re-validated here — do not "restore" this: `validate()` re-reads code
        // existence that cannot have changed since the commit, and costs ~19 EXTCODESIZE reads
        // across both releases PER CHAIN on a function that is permissionless once the deadline
        // passes.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);
        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Type provenance: the object at `_transition` must run the audited `CTMTransition` code.
    function _requireGenuineTransition(ICTMTransition _transition) private view {
        address(_transition).requireObjectType(TRANSITION_CODEHASH);
    }

    /// @dev The reservation every callback after `beginOperation` acts on.
    function _requireActive() private view returns (IEcosystemUpgradeOperation operation) {
        operation = activeOperation;
        if (address(operation) == address(0)) {
            revert NoPendingOperation();
        }
    }

    /// @dev Both transition edges, asserted independently:
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since the commit moves `currentRelease` — rejects replays;
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

    /// @dev The CTM leg: installs the transition and points new-chain genesis at its target
    ///      release. Private by design — the lifecycle cannot be bypassed.
    function _applyCTMUpgrade(ICTMTransition _transition) private {
        _transition.validate();
        (uint256 oldProtocolVersion, uint256 newProtocolVersion) = _requireEdges(_transition);
        // Every bytecode the L2 transaction depends on must already be published on the CTM's
        // supplier — otherwise the committed edge fails on every chain's L2 leg.
        L2PlanLib.requirePublished(
            BytecodesSupplier(CHAIN_TYPE_MANAGER.L1_BYTECODES_SUPPLIER()),
            _transition.l2Plan().factoryDepHashes
        );
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
    }

    /// @dev The shared ChainAssetHandler, read from the bound CTM's Bridgehub.
    function _chainAssetHandler() private view returns (IChainAssetHandlerBase) {
        return IChainAssetHandlerBase(IBridgehubBase(CHAIN_TYPE_MANAGER.BRIDGE_HUB()).chainAssetHandler());
    }
}
