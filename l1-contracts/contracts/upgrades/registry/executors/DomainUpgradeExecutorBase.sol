// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {NoPendingOperation, Unauthorized, UpgradeLifecycleBusy} from "../../../common/L1ContractErrors.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title DomainUpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle bookkeeping both domain executors share: the coordinator binding and the
///         one-operation reservation. Each domain supplies what reserving and releasing its leg means.
abstract contract DomainUpgradeExecutorBase is UpgradeExecutorBase, IDomainUpgradeExecutor {
    /// @inheritdoc IDomainUpgradeExecutor
    address public coordinator;

    /// @inheritdoc IDomainUpgradeExecutor
    IEcosystemUpgradeOperation public activeOperation;

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @param _initialOwner The governance the executor answers to.
    /// @param _coordinator The coordinator it starts bound to; zero leaves it detached.
    constructor(address _initialOwner, address _coordinator) UpgradeExecutorBase(_initialOwner) {
        coordinator = _coordinator;
    }

    /// @inheritdoc IDomainUpgradeExecutor
    function setCoordinator(address _coordinator) external onlyOwner {
        _requireIdle();
        emit CoordinatorChanged(coordinator, _coordinator);
        coordinator = _coordinator;
    }

    /// @inheritdoc IDomainUpgradeExecutor
    function beginOperation(
        IEcosystemUpgradeOperation _operation,
        OperationManifest calldata _manifest
    ) external onlyCoordinator {
        _requireIdle();
        address leg = _reserveLeg(_manifest);
        activeOperation = _operation;
        emit OperationReserved(address(_operation), leg);
    }

    /// @inheritdoc IDomainUpgradeExecutor
    function completeOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        _release();
        _afterCompletion();
        emit OperationCompleted(address(operation));
    }

    /// @inheritdoc IDomainUpgradeExecutor
    function abandonOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        _release();
        emit OperationAbandoned(address(operation));
    }

    /// @notice Checks this domain's leg of `_manifest` and records it.
    /// @return leg The domain's transition object, emitted with the reservation.
    function _reserveLeg(OperationManifest calldata _manifest) internal virtual returns (address leg);

    /// @notice Forgets the leg `_reserveLeg` recorded.
    function _releaseLeg() internal virtual;

    /// @notice What completing an operation does on this domain beyond releasing the reservation.
    function _afterCompletion() internal virtual {}

    /// @dev The reservation every callback after `beginOperation` acts on.
    function _requireActive() internal view returns (IEcosystemUpgradeOperation operation) {
        operation = activeOperation;
        if (address(operation) == address(0)) {
            revert NoPendingOperation();
        }
    }

    function _requireIdle() internal view {
        if (address(activeOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(activeOperation));
        }
    }

    function _release() private {
        delete activeOperation;
        _releaseLeg();
    }
}
