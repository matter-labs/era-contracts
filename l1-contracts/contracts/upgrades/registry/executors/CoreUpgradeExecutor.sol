// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {
    EmptyBytes32,
    LegNotReserved,
    OperationNotPending,
    Unauthorized,
    UpgradeLifecycleBusy,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";

/// @title CoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and applies
///         the shared-singleton implementation swaps pinned in write-once `CoreRegistry` objects.
///         Inside an ecosystem upgrade it acts on the coordinator's instructions for exactly the
///         registry it was reserved for; see {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The owner may also apply a registry directly — the
///      bootstrap edge and recovery run that way, outside any operation.
contract CoreUpgradeExecutor is UpgradeExecutorBase {
    using CodehashPinLib for address;

    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so registry rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @notice `EXTCODEHASH` of the audited `CoreRegistry`. Every registry this executor accepts
    ///         must run exactly that code (see `CTMUpgradeExecutor.TRANSITION_CODEHASH`).
    bytes32 public immutable CORE_REGISTRY_CODEHASH;

    /// @notice The coordinating `EcosystemUpgradeExecutor` allowed to reserve this executor and
    ///         drive its callbacks. Explicit owner wiring, never inferred from ownership shape.
    address public coordinator;

    /// @notice The operation this executor is reserved for, zero when free.
    IEcosystemUpgradeOperation public activeOperation;

    /// @notice Emitted after a registry's rows were applied through the bound admin.
    event L1UpgradeApplied(address indexed coreRegistry);

    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice Emitted when the coordinator reserves this executor for an operation's core leg.
    event OperationReserved(address indexed operation, address indexed coreRegistry);

    /// @notice Emitted by `completeOperation`: the registry is applied and the reservation released.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted by `abandonOperation`: the reservation is released, nothing verified.
    event OperationAbandoned(address indexed operation);

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(
        address _initialOwner,
        ProxyAdmin _proxyAdmin,
        bytes32 _coreRegistryCodehash
    ) UpgradeExecutorBase(_initialOwner) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        if (_coreRegistryCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        PROXY_ADMIN = _proxyAdmin;
        CORE_REGISTRY_CODEHASH = _coreRegistryCodehash;
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

    /// @notice Reserves this executor for `_operation`'s ecosystem leg after checking the registry
    ///         the operation names is a genuine, valid object.
    /// @dev The registry is read from the operation, never passed: the operation is the one place
    ///      it is named.
    /// @param _operation The operation the coordinator is preparing.
    function beginOperation(IEcosystemUpgradeOperation _operation) external onlyCoordinator {
        if (address(activeOperation) != address(0)) {
            revert UpgradeLifecycleBusy(address(activeOperation));
        }
        address coreRegistry = _operation.coreRegistry();
        if (coreRegistry == address(0)) {
            revert ZeroAddress();
        }
        coreRegistry.requirePin(CORE_REGISTRY_CODEHASH);
        ICoreRegistry(coreRegistry).validate();
        activeOperation = _operation;
        emit OperationReserved(address(_operation), coreRegistry);
    }

    /// @notice The registry of the active operation — the only one the coordinator may apply;
    ///         zero when free. Derived from the operation, not stored.
    function reservedCoreRegistry() public view returns (ICoreRegistry) {
        if (address(activeOperation) == address(0)) {
            return ICoreRegistry(address(0));
        }
        return ICoreRegistry(activeOperation.coreRegistry());
    }

    /// @notice Applies a core registry's source-checked implementation swaps through the bound
    ///         `ProxyAdmin`.
    /// @dev Callable by the coordinator for exactly the reserved registry, or by the owner for any
    ///      registry (the bootstrap edge and recovery).
    /// @param _coreRegistry The write-once registry approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external {
        if (msg.sender == coordinator) {
            ICoreRegistry reserved = reservedCoreRegistry();
            if (address(reserved) != address(_coreRegistry)) {
                revert LegNotReserved(address(_coreRegistry), address(reserved));
            }
        } else if (msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        _coreRegistry.validate();
        // One call returns complete typed rows; no per-key rescans of the registry.
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreRegistry.ecosystemRows());
        emit L1UpgradeApplied(address(_coreRegistry));
    }

    /// @notice Requires the reserved registry applied, then releases the reservation.
    /// @dev The ecosystem leg has no pause of its own; what completion adds over abandonment is
    ///      the verification, owned by the domain that applied the rows.
    function completeOperation(IEcosystemUpgradeOperation _operation) external onlyCoordinator {
        _requireActive(_operation);
        ProxyUpgradeRowLib.requireRowsApplied(PROXY_ADMIN, reservedCoreRegistry().ecosystemRows());
        delete activeOperation;
        emit OperationCompleted(address(_operation));
    }

    /// @notice Releases the reservation held for `_operation` without verifying anything.
    function abandonOperation(IEcosystemUpgradeOperation _operation) external onlyCoordinator {
        _requireActive(_operation);
        delete activeOperation;
        emit OperationAbandoned(address(_operation));
    }

    function _requireActive(IEcosystemUpgradeOperation _operation) private view {
        if (address(activeOperation) != address(_operation)) {
            revert OperationNotPending(address(_operation), address(activeOperation));
        }
    }

    /// @notice Reverts unless every row of `_coreRegistry` is applied: each proxy points at its
    ///         pinned `implNew`, read live through the bound `ProxyAdmin`.
    /// @dev The row check describes one edge, not a standing invariant: a later upgrade moves
    ///      proxies past these rows and this then reverts by design.
    function validateUpgradeApplied(ICoreRegistry _coreRegistry) external view {
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        ProxyUpgradeRowLib.requireRowsApplied(PROXY_ADMIN, _coreRegistry.ecosystemRows());
    }
}
