// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";

/// @title ICTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The CTM domain's executor: the coordinator surface ({IDomainUpgradeExecutor}) plus what
///         only the CTM domain does — committing an operation's transition on the bound CTM, and
///         per-chain upgrades. See {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICTMUpgradeExecutor is IDomainUpgradeExecutor {
    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_TYPE_MANAGER() external view returns (IChainTypeManager);

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev Deliberately PERMISSIONLESS: it can only ever accept ownership of the BOUND CTM, and
    ///      only after that CTM's current owner nominated this executor — the nomination is the
    ///      approval. That is what lets `RegistryBootstrapMigration.migrate()` complete the
    ///      handover inside one transaction, so authority is never parked between calls.
    function acceptCTMOwnership() external;

    /// @notice Reverts unless `_transition` ITSELF is the transition committed on the bound CTM
    ///         and the CTM has reached its target — the check `applyOperation` ends with, readable
    ///         afterwards; a replaced transition fails it.
    function validateTransitionApplied(ICTMTransition _transition) external view;

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
