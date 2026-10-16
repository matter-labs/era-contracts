// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";

import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";

/// @title IEcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The surface of the coordinating `EcosystemUpgradeExecutor` governance and tooling use:
///         the bound CTM executor and the one call that executes an operation. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IEcosystemUpgradeExecutor {
    /// @notice Emitted when the owner binds the CTM executor or replaces it with a successor.
    event CTMExecutorChanged(address indexed previousExecutor, address indexed newExecutor);

    /// @notice Emitted by `execute` after every leg of the operation was applied and verified.
    event OperationExecuted(address indexed operation);

    /// @notice The executor of the single CTM coordinated by this contract.
    function ctmExecutor() external view returns (ICTMUpgradeExecutor);

    /// @notice Binds the CTM executor, or replaces it with a successor governing the same CTM.
    /// @param _executor The executor; it must already name this coordinator.
    function setCTMExecutor(ICTMUpgradeExecutor _executor) external;

    /// @notice Executes an operation atomically: validates it, applies the core leg when it names a
    ///         core transition, then the CTM leg (infrastructure rows, then the transition commit),
    ///         each leg verifying what it applied before it returns. Any failure reverts the whole
    ///         call.
    /// @param _operation The write-once operation approved by governance.
    function execute(IEcosystemUpgradeOperation _operation) external;
}
