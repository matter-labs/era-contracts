// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "../libraries/CTMUpgradeComposer.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {IDefaultUpgrade} from "../../IDefaultUpgrade.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {
    EmptyBytes32,
    TransitionReleaseMismatch,
    UpgradeNotPermissionlessYet,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";

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
        address _breakGlassGovernor,
        IChainTypeManager _ctm,
        bytes32 _transitionCodehash
    ) UpgradeExecutorBase(_initialOwner, _breakGlassGovernor) {
        if (address(_ctm) == address(0)) {
            revert ZeroAddress();
        }
        if (_transitionCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        CHAIN_TYPE_MANAGER = _ctm;
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
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            uint256 deadline = CHAIN_TYPE_MANAGER.protocolVersionDeadline(_transition.oldProtocolVersion());
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        // Deliberately NOT re-checked here — do not "restore" these:
        //   - the composed cut embeds `address(_transition)` in its init calldata, and the chain
        //     compares it against the `upgradeCutHash` this CTM committed. That does not merely
        //     prove "a genuine transition"; it proves THE transition `applyCTMUpgrade` committed,
        //     which is strictly stronger than the codehash check.
        //   - `validate()` re-reads pins that cannot have moved: an `EXTCODEHASH` is fixed for a
        //     non-selfdestructible contract, so anything true at `applyCTMUpgrade` is still true.
        //     It also costs ~19 EXTCODEHASH reads across both releases, PER CHAIN, on a function
        //     that is permissionless once the deadline passes.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(
            _chainId,
            _transition.oldProtocolVersion(),
            _buildUpgradeCut(_transition)
        );

        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }

    /// @dev Composes the upgrade cut: an `upgradeEngine.upgradeFromTransition(transition)` init
    ///      delegatecall (no outer `facetCuts` — the engine applies the DERIVED facet swaps,
    ///      reading them from the same transition). Composing HERE keeps the executor the single
    ///      contract that turns a transition into a cut; the chain sees opaque bytes it checks
    ///      against the hash its CTM committed.
    function _buildUpgradeCut(ICTMTransition _transition) private view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.upgradeEngine(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }
}
