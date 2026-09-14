// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "./IEcosystemUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "./CoreUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {GovernanceUpgradeTimer} from "../../GovernanceUpgradeTimer.sol";
import {
    CoordinatorNotBound,
    EmptyBytes32,
    NoPendingOperation,
    OperationNotPending,
    TimerNotBoundToExecutor,
    UpgradeLifecycleBusy,
    UpgradeStageOutOfOrder,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {CTMLeg, OperationManifest} from "../RegistryTypes.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle coordinator of ecosystem upgrades. It owns no proxy administration:
///         stage ordering, timers, the pending operation and completion live here, and the domain
///         executors (`CoreUpgradeExecutor`, one `CTMUpgradeExecutor` per CTM) perform the narrow
///         operations on the authority they hold. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. Every stage takes the pinned write-once
///      `EcosystemUpgradeOperation` governance approved; no caller-supplied calldata enters a
///      stage.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase, IEcosystemUpgradeExecutor {
    using CodehashPinLib for address;

    /// @notice The executor of the ecosystem leg. Immutable: replacing it means replacing the
    ///         coordinator, which each domain does explicitly through its `setCoordinator`.
    CoreUpgradeExecutor public immutable CORE_EXECUTOR;

    /// @notice `EXTCODEHASH` of the audited `EcosystemUpgradeOperation`. Every operation the
    ///         stages accept must run exactly that code, so its legs cannot change between stages.
    bytes32 public immutable OPERATION_CODEHASH;

    /// @inheritdoc IEcosystemUpgradeExecutor
    IEcosystemUpgradeOperation public pendingOperation;

    /// @inheritdoc IEcosystemUpgradeExecutor
    UpgradeStage public pendingStage;

    /// @notice Emitted by `stage0`: every participant is reserved, migrations are paused and the
    ///         transitions' timers are running.
    event OperationPrepared(address indexed operation);

    /// @notice Emitted by `stage1` after the core leg and every CTM leg were applied.
    event OperationExecuted(address indexed operation);

    /// @notice Emitted by `stage2` after every leg verified and every migration pause was released.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted when governance abandons the pending operation.
    event OperationAbandoned(address indexed operation, UpgradeStage stage);

    constructor(
        address _initialOwner,
        CoreUpgradeExecutor _coreExecutor,
        bytes32 _operationCodehash
    ) UpgradeExecutorBase(_initialOwner) {
        if (address(_coreExecutor) == address(0)) {
            revert ZeroAddress();
        }
        if (_operationCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        CORE_EXECUTOR = _coreExecutor;
        OPERATION_CODEHASH = _operationCodehash;
    }

    /// @notice Stage 0 — preparation. Checks every participant answers to this coordinator and
    ///         every timer is bound to it, records the operation, reserves the domains (which
    ///         validate their own leg and pause their migrations) and starts the timers.
    /// @param _operation The write-once operation approved by governance.
    function stage0(IEcosystemUpgradeOperation _operation) external onlyOwner {
        if (address(pendingOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(pendingOperation));
        }
        address(_operation).requirePin(OPERATION_CODEHASH);
        OperationManifest memory m = _operation.getManifest();

        pendingOperation = _operation;
        pendingStage = UpgradeStage.Prepared;

        if (m.coreRegistry != address(0)) {
            _requireBound(address(CORE_EXECUTOR), CORE_EXECUTOR.coordinator());
            CORE_EXECUTOR.beginOperation(_operation, ICoreRegistry(m.coreRegistry));
        }
        uint256 legCount = m.legs.length;
        for (uint256 i = 0; i < legCount; ++i) {
            CTMLeg memory leg = m.legs[i];
            ICTMUpgradeExecutor executor = ICTMUpgradeExecutor(leg.executor);
            _requireBound(leg.executor, executor.coordinator());
            ICTMTransition transition = ICTMTransition(leg.transition);
            // The reservation first: it is where the transition's provenance is checked, so a
            // non-genuine object fails there rather than on an arbitrary getter below.
            executor.beginOperation(_operation, transition);
            // A timer nobody else can start — and one this coordinator can, which `startTimer`
            // would only prove after the reservation is already recorded.
            GovernanceUpgradeTimer timer = GovernanceUpgradeTimer(transition.upgradeTimer());
            address timerGovernance = timer.TIMER_GOVERNANCE();
            if (timerGovernance != address(this)) {
                revert TimerNotBoundToExecutor(address(timer), timerGovernance);
            }
            timer.startTimer();
        }
        emit OperationPrepared(address(_operation));
    }

    /// @notice Stage 1 — execution. Requires every timer's deadline, then applies the core leg
    ///         once and the CTM legs in committed order. Any failure reverts the whole stage.
    /// @param _operation The operation prepared by `stage0`.
    function stage1(IEcosystemUpgradeOperation _operation) external onlyOwner {
        _requirePending(_operation, UpgradeStage.Prepared);
        OperationManifest memory m = _operation.getManifest();
        uint256 legCount = m.legs.length;
        for (uint256 i = 0; i < legCount; ++i) {
            GovernanceUpgradeTimer(ICTMTransition(m.legs[i].transition).upgradeTimer()).checkDeadline();
        }
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.applyL1Upgrade(ICoreRegistry(m.coreRegistry));
        }
        for (uint256 i = 0; i < legCount; ++i) {
            ICTMUpgradeExecutor(m.legs[i].executor).applyTransition(ICTMTransition(m.legs[i].transition));
        }
        pendingStage = UpgradeStage.Executed;
        emit OperationExecuted(address(_operation));
    }

    /// @notice Stage 2 — completion. Checks the core result and every CTM result, then releases
    ///         the reservations and migration pauses and clears the lifecycle slot.
    /// @dev Completion means the L1 edge is complete and the operational restrictions are lifted;
    ///      it does not attest that every chain has finished its own upgrade.
    /// @param _operation The operation executed by `stage1`.
    function stage2(IEcosystemUpgradeOperation _operation) external onlyOwner {
        _requirePending(_operation, UpgradeStage.Executed);
        OperationManifest memory m = _operation.getManifest();
        uint256 legCount = m.legs.length;
        // Every check before any release: a later leg's failure must leave every pause held.
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.validateUpgradeApplied(ICoreRegistry(m.coreRegistry));
        }
        for (uint256 i = 0; i < legCount; ++i) {
            ICTMUpgradeExecutor(m.legs[i].executor).validateTransitionApplied(ICTMTransition(m.legs[i].transition));
        }
        delete pendingOperation;
        pendingStage = UpgradeStage.None;
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.endOperation(_operation);
        }
        for (uint256 i = 0; i < legCount; ++i) {
            ICTMUpgradeExecutor(m.legs[i].executor).completeOperation(_operation);
        }
        emit OperationCompleted(address(_operation));
    }

    /// @notice Break-glass for an operation that cannot complete: frees every reservation and the
    ///         lifecycle slot. Whatever stage 1 already committed stands, and migrations stay
    ///         paused — resuming them is governance's explicit decision.
    function abandonPendingOperation() external onlyOwner {
        IEcosystemUpgradeOperation operation = pendingOperation;
        if (address(operation) == address(0)) {
            revert NoPendingOperation();
        }
        UpgradeStage stage = pendingStage;
        OperationManifest memory m = operation.getManifest();
        delete pendingOperation;
        pendingStage = UpgradeStage.None;
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.endOperation(operation);
        }
        uint256 legCount = m.legs.length;
        for (uint256 i = 0; i < legCount; ++i) {
            ICTMUpgradeExecutor(m.legs[i].executor).abandonOperation(operation);
        }
        emit OperationAbandoned(address(operation), stage);
    }

    /// @dev The lifecycle gate every stage after 0 shares: the named operation is the pending one
    ///      and it sits exactly one stage back.
    function _requirePending(IEcosystemUpgradeOperation _operation, UpgradeStage _expected) private view {
        if (address(pendingOperation) != address(_operation)) {
            revert OperationNotPending(address(_operation), address(pendingOperation));
        }
        if (pendingStage != _expected) {
            revert UpgradeStageOutOfOrder(uint8(pendingStage), uint8(_expected));
        }
    }

    /// @dev A domain that does not name this coordinator has not authorized it — a shared owner
    ///      is not evidence of authorization.
    function _requireBound(address _domain, address _boundCoordinator) private view {
        if (_boundCoordinator != address(this)) {
            revert CoordinatorNotBound(_domain, _boundCoordinator);
        }
    }
}
