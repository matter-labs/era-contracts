// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "./IEcosystemUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "./CoreUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {GovernanceUpgradeTimer} from "../../GovernanceUpgradeTimer.sol";
import {
    ExecutorCoordinatorMismatch,
    CoordinatorCTMMismatch,
    NoPendingOperation,
    OperationNotPending,
    UpgradeLifecycleBusy,
    UpgradeStageOutOfOrder,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle coordinator of ecosystem upgrades. It owns no proxy administration:
///         stage ordering, the timer, the pending operation and completion live here, and the domain
///         executors (`CoreUpgradeExecutor` and one bound `CTMUpgradeExecutor`) perform the narrow
///         operations on the authority they hold. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. Every stage takes the pinned write-once
///      `EcosystemUpgradeOperation` governance approved; no caller-supplied calldata enters a
///      stage.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase, IEcosystemUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The executor of the ecosystem leg. Immutable: replacing it means replacing the
    ///         coordinator, which each domain does explicitly through its `setCoordinator`.
    CoreUpgradeExecutor public immutable CORE_EXECUTOR;

    /// @inheritdoc IEcosystemUpgradeExecutor
    ICTMUpgradeExecutor public ctmExecutor;

    /// @inheritdoc IEcosystemUpgradeExecutor
    IEcosystemUpgradeOperation public pendingOperation;

    /// @inheritdoc IEcosystemUpgradeExecutor
    UpgradeStage public pendingStage;

    constructor(address _initialOwner, CoreUpgradeExecutor _coreExecutor) UpgradeExecutorBase(_initialOwner) {
        if (address(_coreExecutor) == address(0)) {
            revert ZeroAddress();
        }
        CORE_EXECUTOR = _coreExecutor;
    }

    /// @notice Binds the CTM executor, or replaces it with a successor governing the same CTM.
    function setCTMExecutor(ICTMUpgradeExecutor _executor) external onlyOwner {
        if (address(pendingOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(pendingOperation));
        }
        if (address(_executor) == address(0)) {
            revert ZeroAddress();
        }
        ObjectAnchorLib.requireCode(address(_executor));
        address boundCoordinator = _executor.coordinator();
        if (boundCoordinator != address(this)) {
            revert ExecutorCoordinatorMismatch(address(this), boundCoordinator);
        }
        address nextCTM = address(_executor.CHAIN_TYPE_MANAGER());
        if (nextCTM == address(0)) {
            revert ZeroAddress();
        }
        if (address(ctmExecutor) != address(0)) {
            address currentCTM = address(ctmExecutor.CHAIN_TYPE_MANAGER());
            if (nextCTM != currentCTM) {
                revert CoordinatorCTMMismatch(currentCTM, nextCTM);
            }
        }
        emit CTMExecutorChanged(address(ctmExecutor), address(_executor));
        ctmExecutor = _executor;
    }

    /// @notice Stage 0 — preparation. Records the operation, reserves every domain (each
    ///         validates its own leg and answers only to its coordinator; the CTM executor pauses
    ///         migrations) and starts the operation's timer.
    /// @param _operation The write-once operation approved by governance.
    function stage0(IEcosystemUpgradeOperation _operation) external onlyOwner {
        if (address(pendingOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(pendingOperation));
        }
        address(_operation).requireCode();
        _operation.validate();
        OperationManifest memory m = _operation.getManifest();

        pendingOperation = _operation;
        pendingStage = UpgradeStage.Prepared;

        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.beginOperation(_operation);
        }
        if (address(ctmExecutor) == address(0)) {
            revert ZeroAddress();
        }
        // The CTM domain is reserved for EVERY operation, transition or not: an infrastructure
        // change swaps implementations under chains that may be migrating.
        ctmExecutor.beginOperation(_operation);
        GovernanceUpgradeTimer(m.timer).startTimer();
        emit OperationPrepared(address(_operation));
    }

    /// @notice Stage 1 — execution. Requires the timer's deadline, then applies the core leg
    ///         once and the CTM leg. Any failure reverts the whole stage.
    /// @param _operation The operation prepared by `stage0`.
    function stage1(IEcosystemUpgradeOperation _operation) external onlyOwner {
        _requirePending(_operation, UpgradeStage.Prepared);
        OperationManifest memory m = _operation.getManifest();
        GovernanceUpgradeTimer(m.timer).checkDeadline();
        // The stage advances before the domains are driven: any leg's revert unwinds the whole
        // stage, so nothing observes `Executed` with a leg still unapplied.
        pendingStage = UpgradeStage.Executed;
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.applyL1Upgrade(ICoreRegistry(m.coreRegistry));
        }
        ctmExecutor.applyOperation();
        emit OperationExecuted(address(_operation));
    }

    /// @notice Stage 2 — completion. Every domain verifies its own result and releases its
    ///         reservation (the CTM executor also releases its migration pause); the lifecycle slot clears.
    /// @dev One transaction: a later domain's failed verification rolls back every earlier
    ///      release, so no pause is lifted unless every leg verified. Completion means the L1 edge
    ///      is complete and the operational restrictions are lifted; it does not attest that every
    ///      chain has finished its own upgrade.
    /// @param _operation The operation executed by `stage1`.
    function stage2(IEcosystemUpgradeOperation _operation) external onlyOwner {
        _requirePending(_operation, UpgradeStage.Executed);
        OperationManifest memory m = _operation.getManifest();
        delete pendingOperation;
        pendingStage = UpgradeStage.None;
        if (m.coreRegistry != address(0)) {
            CORE_EXECUTOR.completeOperation();
        }
        ctmExecutor.completeOperation();
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
            CORE_EXECUTOR.abandonOperation();
        }
        ctmExecutor.abandonOperation();
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
}
