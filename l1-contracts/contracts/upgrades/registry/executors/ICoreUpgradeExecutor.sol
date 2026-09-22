// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreTransition} from "../objects/ICoreTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";

/// @title ICoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The surface of a `CoreUpgradeExecutor` the coordinating `EcosystemUpgradeExecutor`
///         drives and other readers query: the coordinator it answers to, the operation it is
///         reserved for, and the narrow domain callbacks. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICoreUpgradeExecutor {
    /// @notice Emitted after a core transition's rows were applied through the bound admin.
    event L1UpgradeApplied(address indexed coreTransition);

    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice Emitted when the coordinator reserves this executor for an operation's core leg.
    event OperationReserved(address indexed operation, address indexed coreTransition);

    /// @notice Emitted by `completeOperation`: the core transition is applied and the reservation released.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted by `abandonOperation`: the reservation is released, nothing verified.
    event OperationAbandoned(address indexed operation);

    /// @notice The coordinating `EcosystemUpgradeExecutor` allowed to reserve this executor and
    ///         drive its callbacks. Explicit owner wiring, never inferred from ownership shape.
    function coordinator() external view returns (address);

    /// @notice The operation this executor is reserved for, zero when free.
    function activeOperation() external view returns (IEcosystemUpgradeOperation);

    /// @notice The core transition of the active operation — the only one the coordinator may apply;
    ///         zero when free. Derived from the operation, not stored.
    function reservedCoreTransition() external view returns (ICoreTransition);

    /// @notice Reserves this executor for `_operation`'s ecosystem leg after checking the transition
    ///         the operation names is a genuine, valid object.
    /// @param _operation The operation the coordinator is preparing.
    function beginOperation(IEcosystemUpgradeOperation _operation) external;

    /// @notice Applies a core transition's source-checked implementation swaps through the bound
    ///         `ProxyAdmin`.
    /// @param _coreTransition The write-once core transition approved by governance.
    function applyL1Upgrade(ICoreTransition _coreTransition) external;

    /// @notice Requires the reserved transition applied, then releases the reservation.
    function completeOperation() external;

    /// @notice Releases the reservation this executor holds without verifying anything.
    function abandonOperation() external;

    /// @notice Reverts unless every row of `_coreTransition` is applied: each proxy points at its
    ///         `implNew`, read live through the bound `ProxyAdmin`.
    function validateUpgradeApplied(ICoreTransition _coreTransition) external view;
}
