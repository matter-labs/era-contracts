// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {OperationManifest} from "../RegistryTypes.sol";
import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";

/// @title ICTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The CTM domain's executor: the lifecycle surface ({IDomainUpgradeExecutor}) plus what
///         only the CTM domain does — committing the reserved transition on the bound CTM, the
///         migration pause, and per-chain upgrades. See {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICTMUpgradeExecutor is IDomainUpgradeExecutor {
    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_TYPE_MANAGER() external view returns (IChainTypeManager);

    /// @notice The transition of the active operation's leg on this executor; zero when the
    ///         executor is free OR the reserved operation changes infrastructure only.
    function reservedTransition() external view returns (ICTMTransition);

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev Deliberately PERMISSIONLESS: it can only ever accept ownership of the BOUND CTM, and
    ///      only after that CTM's current owner nominated this executor — the nomination is the
    ///      approval. That is what lets `RegistryBootstrapMigration.migrate()` complete the
    ///      handover inside one transaction, so authority is never parked between calls.
    function acceptCTMOwnership() external;

    /// @notice Applies the reserved operation's CTM leg — its infrastructure rows, then the reserved
    ///         transition when there is one — and verifies the result before returning: every row
    ///         at its `implNew`, the transition's departure committed and its target reached.
    /// @param _manifest The operation's pinned manifest; it must be the one `beginOperation` reserved.
    function applyOperation(OperationManifest calldata _manifest) external;

    /// @notice Lifts this CTM's migration pause while no operation is reserved — the coordinator's
    ///         route for abandoning an operation without leaving its pause behind.
    function releaseMigrationPause() external;

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

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `applyOperation` committed to.
    /// @dev Execution policy, in order of precedence:
    ///      - the OWNER may upgrade any chain at any time;
    ///      - a CHAIN'S OWN ADMIN may upgrade that chain at any time — upgrading is the chain's
    ///        decision to make, and the check is scoped per chain because `_chainId` is an
    ///        argument: an unscoped admin check would let any chain's admin upgrade every other
    ///        chain on this CTM, including ones deliberately waiting to finalize batches first;
    ///      - ANYONE ELSE only once the old-version deadline has passed, at which point the
    ///        upgrade is operationally mandatory and execution carries no discretionary inputs.
    ///      The chain-side `upgradeTimestamp` gate applies to non-admin callers regardless.
    /// @param _transition The transition the CTM currently commits for the chain's departure
    ///        (`upgradeTransition`) — after a replacement, the replacement, never the replaced one.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external;
}
