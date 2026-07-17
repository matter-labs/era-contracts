// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {ICTMTransition} from "./ICTMTransition.sol";
import {CTMUpgradeComposer} from "./CTMUpgradeComposer.sol";
import {UpgradeExecutorBase} from "../../governance/UpgradeExecutorBase.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IDefaultUpgrade} from "../IDefaultUpgrade.sol";
import {TransitionReleaseMismatch, UpgradeNotPermissionlessYet, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../state-transition/L1StateTransitionErrors.sol";

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
    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM.
    IChainTypeManager public immutable CTM;

    /// @notice Emitted after the bound CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(address indexed transition, uint256 oldProtocolVersion, uint256 newProtocolVersion);

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(uint256 indexed chainId, uint256 newProtocolVersion);

    constructor(
        address _initialOwner,
        address _breakGlassGovernor,
        IChainTypeManager _ctm
    ) UpgradeExecutorBase(_initialOwner, _breakGlassGovernor) {
        if (address(_ctm) == address(0)) {
            revert ZeroAddress();
        }
        CTM = _ctm;
    }

    /// @notice Completes the two-step ownership handover of the bound CTM to this executor.
    /// @dev A narrow, fixed entrypoint so the standard handover does not depend on break-glass.
    function acceptCTMOwnership() external onlyOwner {
        Ownable2Step(address(CTM)).acceptOwnership();
    }

    /// @notice Installs the transition and points new-chain genesis at its target release.
    /// @dev Both transition edges are asserted independently BEFORE any mutation:
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since `applyCTMUpgrade` moves `currentRelease` — rejects replays;
    ///      - the version edge (`protocolVersion == oldProtocolVersion`) rejects the wrong
    ///        version schedule (also re-checked inside `setNewVersionUpgrade`).
    /// @param _transition The write-once transition approved by governance.
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        _transition.validate();

        address currentRelease = CTM.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }

        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        uint256 newProtocolVersion = _transition.newProtocolVersion();

        uint256 currentProtocolVersion = CTM.protocolVersion();
        if (currentProtocolVersion != oldProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, oldProtocolVersion);
        }

        CTM.setNewVersionUpgrade({
            _cutData: _buildUpgradeCut(_transition),
            _oldProtocolVersion: oldProtocolVersion,
            _oldProtocolVersionDeadline: _transition.oldProtocolVersionDeadline(),
            _newProtocolVersion: newProtocolVersion,
            _verifier: _transition.verifier()
        });
        CTM.setCurrentRelease(_transition.newRelease());

        emit CTMUpgradeApplied(address(_transition), oldProtocolVersion, newProtocolVersion);
    }

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev Execution policy: owner-driven during the upgrade window, PERMISSIONLESS once the
    ///      old-version deadline has passed — at that point the upgrade is operationally
    ///      mandatory and execution carries no discretionary inputs (the cut is recomposed from
    ///      the pinned transition and checked against the committed `upgradeCutHash`; the
    ///      chain-side `upgradeTimestamp` gate still applies). Chain admins additionally retain
    ///      their own direct execution path on the chain diamond, independent of this executor.
    /// @param _transition The same transition committed by `applyCTMUpgrade`.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        if (msg.sender != owner()) {
            uint256 deadline = CTM.protocolVersionDeadline(_transition.oldProtocolVersion());
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        _transition.validate();

        CTM.upgradeChainFromVersion(_chainId, _transition.oldProtocolVersion(), _buildUpgradeCut(_transition));

        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }

    /// @dev Composes the upgrade cut: an `upgradeEngine.upgradeFromTransition(transition)` init
    ///      delegatecall (no outer `facetCuts` — the engine applies the DERIVED facet swaps,
    ///      reading them from the same transition). The cut is chain-independent, so a single
    ///      cut is committed once and applied to every chain.
    function _buildUpgradeCut(ICTMTransition _transition) private view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.upgradeEngine(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }
}
