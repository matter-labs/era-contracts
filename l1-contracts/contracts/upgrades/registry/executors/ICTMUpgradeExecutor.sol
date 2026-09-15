// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";

/// @title ICTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The surface of a `CTMUpgradeExecutor` the coordinating `EcosystemUpgradeExecutor`
///         drives and other readers query: the bound CTM, the coordinator it answers to, the
///         operation it is reserved for, and the narrow domain callbacks. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICTMUpgradeExecutor {
    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_TYPE_MANAGER() external view returns (IChainTypeManager);

    /// @notice `EXTCODEHASH` every transition this executor accepts must run.
    // solhint-disable-next-line func-name-mixedcase
    function TRANSITION_CODEHASH() external view returns (bytes32);

    /// @notice The only address allowed to drive the lifecycle callbacks below.
    function coordinator() external view returns (address);

    /// @notice The operation this executor is reserved for, zero when free.
    function activeOperation() external view returns (IEcosystemUpgradeOperation);

    /// @notice The transition of the active operation's leg on this executor; zero when the
    ///         executor is free OR the reserved operation changes infrastructure only. Derived
    ///         from the operation, not stored.
    function reservedTransition() external view returns (ICTMTransition);

    /// @notice Reserves this executor for its leg of `_operation`, checks that leg (the
    ///         infrastructure rows, and the transition against the bound CTM when it carries one),
    ///         and pauses the CTM's chain migrations.
    function beginOperation(IEcosystemUpgradeOperation _operation) external;

    /// @notice Applies the reserved operation's CTM leg: its infrastructure rows, then its
    ///         transition when it carries one.
    function applyOperation() external;

    /// @notice Requires the reserved leg applied, unpauses the CTM's migrations and frees the
    ///         reservation.
    function completeOperation() external;

    /// @notice Frees the reservation, leaving migrations paused.
    function abandonOperation() external;

    /// @notice Reverts unless `_transition` has been committed on the bound CTM.
    function validateTransitionApplied(ICTMTransition _transition) external view;

    /// @notice Reverts unless `_operation`'s whole CTM leg has been applied: every infrastructure
    ///         row is live (each read through the admin it names) and its transition, if any, is
    ///         committed. The post-state counterpart of `applyOperation`, and the check stage 2
    ///         makes before it lifts the migration pause.
    function validateOperationApplied(IEcosystemUpgradeOperation _operation) external view;
}
