// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreTransition} from "../objects/ICoreTransition.sol";
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
    OperationManifestChanged,
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

    /// @inheritdoc IEcosystemUpgradeExecutor
    bytes32 public pendingManifestHash;

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
        bytes32 manifestHash = _operation.manifestHash();
        _requireServes(m, manifestHash);

        pendingOperation = _operation;
        pendingStage = UpgradeStage.Prepared;
        pendingManifestHash = manifestHash;

        if (m.coreTransition != address(0)) {
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
    ///         once and the CTM leg, each verifying its own result before it returns. Any failure
    ///         reverts the whole stage.
    /// @param _operation The operation prepared by `stage0`.
    function stage1(IEcosystemUpgradeOperation _operation) external onlyOwner {
        OperationManifest memory m = _requirePending(_operation, UpgradeStage.Prepared);
        GovernanceUpgradeTimer(m.timer).checkDeadline();
        // The stage advances before the domains are driven: any leg's revert unwinds the whole
        // stage, so nothing observes `Executed` with a leg still unapplied.
        pendingStage = UpgradeStage.Executed;
        if (m.coreTransition != address(0)) {
            CORE_EXECUTOR.applyL1Upgrade(ICoreTransition(m.coreTransition));
        }
        ctmExecutor.applyOperation();
        emit OperationExecuted(address(_operation));
    }

    /// @notice Stage 2 — completion. Requires the timer's deadline again, then every domain
    ///         releases its reservation (the CTM executor also releases its migration pause); the
    ///         lifecycle slot clears.
    /// @dev Stage 1 already verified what it applied, so nothing here re-reads it: see "Stages" in
    ///      {protocol-docs/ecosystem-upgrade-coordination.md}.
    /// @param _operation The operation executed by `stage1`.
    function stage2(IEcosystemUpgradeOperation _operation) external onlyOwner {
        OperationManifest memory m = _requirePending(_operation, UpgradeStage.Executed);
        GovernanceUpgradeTimer(m.timer).checkDeadline();
        delete pendingOperation;
        pendingStage = UpgradeStage.None;
        delete pendingManifestHash;
        if (m.coreTransition != address(0)) {
            CORE_EXECUTOR.completeOperation();
        }
        ctmExecutor.completeOperation();
        emit OperationCompleted(address(_operation));
    }

    /// @notice Break-glass for an operation that cannot complete: frees every reservation and the
    ///         lifecycle slot. Whatever stage 1 already committed stands.
    /// @param _unpauseMigrations Whether the CTM executor also lifts this CTM's migration pause;
    ///        otherwise the pause stays held until governance lifts it.
    function abandonPendingOperation(bool _unpauseMigrations) external onlyOwner {
        IEcosystemUpgradeOperation operation = pendingOperation;
        if (address(operation) == address(0)) {
            revert NoPendingOperation();
        }
        UpgradeStage stage = pendingStage;
        OperationManifest memory m = operation.getManifest();
        delete pendingOperation;
        pendingStage = UpgradeStage.None;
        delete pendingManifestHash;
        if (m.coreTransition != address(0)) {
            CORE_EXECUTOR.abandonOperation();
        }
        ctmExecutor.abandonOperation(_unpauseMigrations);
        emit OperationAbandoned(address(operation), stage);
    }

    /// @dev The lifecycle gate every stage after 0 shares: the named operation is the pending one,
    ///      it sits exactly one stage back, and it still serves the manifest stage 0 pinned.
    /// @return m The operation's manifest.
    function _requirePending(
        IEcosystemUpgradeOperation _operation,
        UpgradeStage _expected
    ) private view returns (OperationManifest memory m) {
        if (address(pendingOperation) != address(_operation)) {
            revert OperationNotPending(address(_operation), address(pendingOperation));
        }
        if (pendingStage != _expected) {
            revert UpgradeStageOutOfOrder(uint8(pendingStage), uint8(_expected));
        }
        m = _operation.getManifest();
        bytes32 pinned = pendingManifestHash;
        bytes32 served = _operation.manifestHash();
        if (served != pinned) {
            revert OperationManifestChanged(pinned, served);
        }
        _requireServes(m, pinned);
    }

    /// @dev The manifest an operation decodes must be the one its hash commits to, so the hash
    ///      pinned at stage 0 covers every field the stages read.
    /// @param _manifest The manifest the operation served.
    /// @param _manifestHash The commitment it is held to.
    function _requireServes(OperationManifest memory _manifest, bytes32 _manifestHash) private pure {
        bytes32 decoded = keccak256(abi.encode(_manifest));
        if (decoded != _manifestHash) {
            revert OperationManifestChanged(_manifestHash, decoded);
        }
    }
}
