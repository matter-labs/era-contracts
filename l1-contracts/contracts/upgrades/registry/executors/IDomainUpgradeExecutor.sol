// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OperationManifest} from "../RegistryTypes.sol";

/// @title IDomainUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The surface the coordinating `EcosystemUpgradeExecutor` drives on each domain executor:
///         the coordinator it answers to, and the apply callback of its leg of an operation. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IDomainUpgradeExecutor {
    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice The only address allowed to drive `applyOperation`; zero detaches the executor.
    function coordinator() external view returns (address);

    /// @notice Points this executor at a coordinator (zero detaches it).
    /// @param _coordinator The new coordinator.
    function setCoordinator(address _coordinator) external;

    /// @notice Applies this domain's leg of the operation the coordinator is executing, and
    ///         verifies the result before returning.
    /// @param _manifest The operation's manifest as the coordinator read and hash-checked it; the
    ///        executor reads its leg from this argument and never calls the operation.
    function applyOperation(OperationManifest calldata _manifest) external;
}
