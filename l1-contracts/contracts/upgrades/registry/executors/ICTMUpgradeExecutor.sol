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
    /// @notice Emitted when the owner points this executor at another coordinator.
    event CoordinatorChanged(address indexed previousCoordinator, address indexed newCoordinator);

    /// @notice Emitted by `beginOperation`: the operation's CTM leg is reserved and the CTM's
    ///         chain migrations are paused. `transition` is zero for an infrastructure-only leg.
    event OperationReserved(address indexed operation, address indexed transition);

    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted by `completeOperation`: the reservation is released and migrations resume.
    event OperationCompleted(address indexed operation);

    /// @notice Emitted by `abandonOperation`: the reservation is released.
    event OperationAbandoned(address indexed operation);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_TYPE_MANAGER() external view returns (IChainTypeManager);

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

    /// @notice Applies the reserved operation's CTM leg — its infrastructure rows, then its
    ///         transition when it carries one — and verifies the result before returning: every row
    ///         at its `implNew`, the transition's departure committed and its target reached.
    function applyOperation() external;

    /// @notice Unpauses the CTM's migrations and frees the reservation.
    function completeOperation() external;

    /// @notice Frees the reservation.
    /// @param _unpauseMigrations Whether to lift the CTM's migration pause too; otherwise it stays
    ///        held until governance lifts it.
    function abandonOperation(bool _unpauseMigrations) external;

    /// @notice Reverts unless `_transition` ITSELF is the transition committed on the bound CTM
    ///         and the CTM has reached its target; a replaced transition fails it.
    function validateTransitionApplied(ICTMTransition _transition) external view;

    /// @notice Reverts unless the departure `_operation`'s transition committed is still committed
    ///         on the bound CTM — by that transition or by a replacement of it — and the CTM has
    ///         reached its target: the check `applyOperation` ends with, readable afterwards.
    /// @dev Reverts for an infrastructure-only operation: its rows describe one moment of
    ///      implementation history that a later re-patch legitimately moves, so there is no
    ///      applied state to read back.
    function validateOperationApplied(IEcosystemUpgradeOperation _operation) external view;
}
