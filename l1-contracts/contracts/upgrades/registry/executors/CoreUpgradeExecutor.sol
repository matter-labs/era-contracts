// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreTransition} from "../objects/ICoreTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICoreUpgradeExecutor} from "./ICoreUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {
    LegNotReserved,
    NoPendingOperation,
    Unauthorized,
    UpgradeLifecycleBusy,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";

/// @title CoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and applies
///         the shared-singleton implementation swaps pinned in write-once `CoreTransition` objects.
///         Inside an ecosystem upgrade it acts on the coordinator's instructions for exactly the
///         core transition it was reserved for; see {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The owner may also apply a core transition directly — the
///      bootstrap edge and recovery run that way, outside any operation.
contract CoreUpgradeExecutor is UpgradeExecutorBase, ICoreUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so transition rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @inheritdoc ICoreUpgradeExecutor
    address public coordinator;

    /// @inheritdoc ICoreUpgradeExecutor
    IEcosystemUpgradeOperation public activeOperation;

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(address _initialOwner, ProxyAdmin _proxyAdmin) UpgradeExecutorBase(_initialOwner) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        PROXY_ADMIN = _proxyAdmin;
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

    /// @inheritdoc ICoreUpgradeExecutor
    /// @dev The core transition is read from the operation, never passed: the operation is the one place
    ///      it is named.
    function beginOperation(IEcosystemUpgradeOperation _operation) external onlyCoordinator {
        if (address(activeOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(activeOperation));
        }
        address coreTransition = _operation.coreTransition();
        if (coreTransition == address(0)) {
            revert ZeroAddress();
        }
        coreTransition.requireCode();
        ICoreTransition(coreTransition).validate();
        activeOperation = _operation;
        emit OperationReserved(address(_operation), coreTransition);
    }

    /// @inheritdoc ICoreUpgradeExecutor
    function reservedCoreTransition() public view returns (ICoreTransition) {
        if (address(activeOperation) == address(0)) {
            return ICoreTransition(address(0));
        }
        return ICoreTransition(activeOperation.coreTransition());
    }

    /// @inheritdoc ICoreUpgradeExecutor
    /// @dev Callable by the coordinator for exactly the reserved core transition, or by the owner
    ///      for any core transition (the bootstrap edge and recovery).
    function applyL1Upgrade(ICoreTransition _coreTransition) external {
        if (msg.sender == coordinator) {
            ICoreTransition reserved = reservedCoreTransition();
            if (address(reserved) != address(_coreTransition)) {
                revert LegNotReserved(address(_coreTransition), address(reserved));
            }
        } else if (msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        address(_coreTransition).requireCode();
        _coreTransition.validate();
        // One call returns complete typed rows; no per-key rescans of the transition.
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreTransition.ecosystemRows());
        emit L1UpgradeApplied(address(_coreTransition));
    }

    /// @inheritdoc ICoreUpgradeExecutor
    /// @dev The ecosystem leg has no pause of its own; what completion adds over abandonment is
    ///      the verification, owned by the domain that applied the rows.
    function completeOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        ProxyUpgradeRowLib.requireRowsApplied(PROXY_ADMIN, reservedCoreTransition().ecosystemRows());
        delete activeOperation;
        emit OperationCompleted(address(operation));
    }

    /// @inheritdoc ICoreUpgradeExecutor
    function abandonOperation() external onlyCoordinator {
        IEcosystemUpgradeOperation operation = _requireActive();
        delete activeOperation;
        emit OperationAbandoned(address(operation));
    }

    /// @dev The reservation every callback after `beginOperation` acts on.
    function _requireActive() private view returns (IEcosystemUpgradeOperation operation) {
        operation = activeOperation;
        if (address(operation) == address(0)) {
            revert NoPendingOperation();
        }
    }

    /// @inheritdoc ICoreUpgradeExecutor
    /// @dev The row check describes one edge, not a standing invariant: a later upgrade moves
    ///      proxies past these rows and this then reverts by design.
    function validateUpgradeApplied(ICoreTransition _coreTransition) external view {
        address(_coreTransition).requireCode();
        ProxyUpgradeRowLib.requireRowsApplied(PROXY_ADMIN, _coreTransition.ecosystemRows());
    }
}
