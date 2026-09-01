// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {
    EmptyBytes32,
    TransitionNotCommitted,
    TransitionReleaseMismatch,
    UpgradeNotPermissionlessYet,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor BOUND to one immutable ChainTypeManager: it owns that CTM
///         and drives the version bump, upgrade cut and chain upgrades from pinned, write-once
///         `CTMTransition` objects. CTM authority is deliberately separate from ecosystem
///         authority (`EcosystemUpgradeExecutor`): each CTM is governed by its own executor and
///         upgrades on its own cadence.
/// @dev Fixed logic, no generic delegatecall. The break-glass `forward` (base) is gated by a
///      SEPARATE governor. The transition each entrypoint takes is a *pinned implementation
///      address* — the exact generated contract governance approved — never a proxy.
contract CTMUpgradeExecutor is UpgradeExecutorBase {
    using CodehashPinLib for address;

    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies (validator timelock, server notifier). Owned by this executor, so
    ///         a transition's `ctmProxyRows` (including the CTM's own implementation swap) apply
    ///         through the same authority that commits the transition. Deliberately NOT the
    ///         ecosystem `ProxyAdmin`: a CTM is one of possibly many and upgrades on its own
    ///         cadence, so nothing CTM-scoped sits under ecosystem authority.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    /// @notice `EXTCODEHASH` of the audited `CTMTransition`. Every transition this executor accepts
    ///         must run exactly that code — which, since the manifest is written in the constructor
    ///         and no setter exists, makes "canonical write-once object" an on-chain invariant: an
    ///         arbitrary contract (or upgradeable proxy) merely implementing `ICTMTransition` is
    ///         rejected. Manifest CONTENT is not gated here and never was; governance approving the
    ///         address is what gates content.
    bytes32 public immutable TRANSITION_CODEHASH;

    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    constructor(
        address _initialOwner,
        address _emergencyUpgradeBoard,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin,
        bytes32 _transitionCodehash
    ) UpgradeExecutorBase(_initialOwner, _emergencyUpgradeBoard) {
        if (address(_ctm) == address(0) || address(_ctmProxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        if (_transitionCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        CHAIN_TYPE_MANAGER = _ctm;
        CTM_PROXY_ADMIN = _ctmProxyAdmin;
        TRANSITION_CODEHASH = _transitionCodehash;
    }

    /// @dev Type provenance: the object at `_transition` must run the audited `CTMTransition` code.
    function _requireGenuineTransition(ICTMTransition _transition) private view {
        address(_transition).requirePin(TRANSITION_CODEHASH);
    }

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev A narrow, fixed entrypoint so the standard handover does not depend on break-glass.
    function acceptCTMOwnership() external onlyOwner {
        Ownable2Step(address(CHAIN_TYPE_MANAGER)).acceptOwnership();
    }

    /// @notice Moves a departed protocol version's deadline on the bound CTM.
    /// @dev A fixed entrypoint rather than break-glass: the deadline is routine operational state
    ///      that keeps changing after a transition commits (extended while chains lag, shortened
    ///      to retire a version), and the transition's pinned value is only its starting point.
    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external onlyOwner {
        CHAIN_TYPE_MANAGER.setProtocolVersionDeadline(_protocolVersion, _timestamp);
    }

    /// @notice Installs the transition and points new-chain genesis at its target release.
    /// @dev Both transition edges are asserted independently BEFORE any mutation:
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since `applyCTMUpgrade` moves `currentRelease` — rejects replays;
    ///      - the version edge (`protocolVersion == oldProtocolVersion`) rejects the wrong
    ///        version schedule (also re-checked inside `setNewVersionUpgrade`).
    /// @param _transition The write-once transition approved by governance.
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        _requireGenuineTransition(_transition);
        _transition.validate();

        address currentRelease = CHAIN_TYPE_MANAGER.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }

        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        uint256 newProtocolVersion = _transition.newProtocolVersion();

        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion != oldProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, oldProtocolVersion);
        }

        // CTM-domain implementation swaps FIRST — the commit below may need setters that only
        // exist on the implementation this very transition installs (the bootstrap's
        // "ordering is load-bearing" rule, made permanent).
        ProxyUpgradeRowLib.applyRows(CTM_PROXY_ADMIN, _transition.ctmProxyRows());

        // One argument, not four plus a cut: the CTM reads the version edge, the schedule and the
        // cut from the same pinned object, so they cannot be passed inconsistently.
        CHAIN_TYPE_MANAGER.setNewVersionUpgradeFromTransition(_transition);
        CHAIN_TYPE_MANAGER.setCurrentRelease(_transition.newRelease());

        emit CTMUpgradeApplied(address(_transition), oldProtocolVersion, newProtocolVersion);
    }

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev Execution policy, in order of precedence:
    ///      - the OWNER may upgrade any chain at any time;
    ///      - a CHAIN'S OWN ADMIN may upgrade that chain at any time — upgrading is the chain's
    ///        decision to make, and the check is scoped per chain because `_chainId` is an
    ///        argument: an unscoped admin check would let any chain's admin upgrade every other
    ///        chain on this CTM, including ones deliberately waiting to finalize batches first;
    ///      - ANYONE ELSE only once the old-version deadline has passed, at which point the
    ///        upgrade is operationally mandatory and execution carries no discretionary inputs.
    ///      The chain-side `upgradeTimestamp` gate applies to non-admin callers regardless.
    /// @param _transition The same transition committed by `applyCTMUpgrade`.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            uint256 deadline = CHAIN_TYPE_MANAGER.protocolVersionDeadline(oldProtocolVersion);
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        // The chain executes the cut its own CTM committed, so `_transition` must BE that
        // transition — otherwise the argument would name one edge while a different one ran.
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        // Deliberately NOT re-checked here — do not "restore" this:
        //   - `validate()` re-reads pins that cannot have moved: an `EXTCODEHASH` is fixed for a
        //     non-selfdestructible contract, so anything true at `applyCTMUpgrade` is still true.
        //     It also costs ~19 EXTCODEHASH reads across both releases, PER CHAIN, on a function
        //     that is permissionless once the deadline passes.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);

        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }
}
