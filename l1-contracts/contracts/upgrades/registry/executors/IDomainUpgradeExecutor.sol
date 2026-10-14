// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title IDomainUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle surface the coordinating `EcosystemUpgradeExecutor` drives on each domain
///         executor: the coordinator it answers to, the operation it is reserved for, and the
///         reserve / complete / abandon callbacks. See {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IDomainUpgradeExecutor {
    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice Emitted by `beginOperation`: the operation's leg on this domain is reserved. `leg` is
    ///         the domain's transition object, zero for a CTM leg that changes infrastructure only.
    event OperationReserved(address indexed operation, address indexed leg);

    /// @notice Emitted by `completeOperation`: the reservation is released.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted by `abandonOperation`: the reservation is released without completing.
    event OperationAbandoned(address indexed operation);

    /// @notice The only address allowed to drive the lifecycle callbacks; zero detaches the executor.
    function coordinator() external view returns (address);

    /// @notice The operation this executor is reserved for, zero when free.
    function activeOperation() external view returns (IEcosystemUpgradeOperation);

    /// @notice Points this executor at a coordinator (zero detaches it). Refused while reserved, so
    ///         one operation is prepared, executed and completed by one coordinator.
    /// @param _coordinator The new coordinator.
    function setCoordinator(address _coordinator) external;

    /// @notice Reserves this executor for its leg of `_operation` after checking that leg.
    /// @param _operation The operation the coordinator is preparing.
    /// @param _manifest The operation's manifest as the coordinator read and pinned it; the executor
    ///        reads its leg from this argument and never calls the operation.
    function beginOperation(IEcosystemUpgradeOperation _operation, OperationManifest calldata _manifest) external;

    /// @notice Releases the reservation of an operation stage 1 executed.
    function completeOperation() external;

    /// @notice Releases the reservation without completing the operation; whatever stage 1 already
    ///         applied stands.
    function abandonOperation() external;
}
